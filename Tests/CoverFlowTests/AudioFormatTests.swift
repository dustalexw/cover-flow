import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import CoverFlow

/// Formats decoded through the bundled FFmpeg build. The fixtures hold one second of a
/// 440 Hz sine, except tone.spx (16 kHz mono), tone.mpc (44.1 kHz) and tone.dsf (0.1 s of
/// DSD64 at amplitude 1/4, made by scripts/make-dsd-fixture.py). The sine is ffmpeg's
/// amplitude 1/8, and ffmpeg's mono-to-stereo upmix lowered it by 3 dB, to an RMS of 0.0625.
/// tone.spx is mono, so not upmixed, but Speex's low-bitrate coding brings it to about the
/// same level.
/// tags.* carry the same tags as the other tag fixtures; tags.ogg also has a PNG cover.
final class AudioFormatTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func fixture(_ name: String) -> URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures/" + name)
    }

    private func copy(_ name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try FileManager.default.copyItem(at: fixture(name), to: url)
        return url
    }

    /// The left channel at the player's 48 kHz stereo output.
    private func decode(_ url: URL, start: Double = 0) async throws -> [Float] {
        let decoder = try PCMDecoder(url: url, start: start)
        var samples: [Float] = []
        while let chunk = try await decoder.read() {
            samples += UnsafeBufferPointer(start: chunk.buffer.floatChannelData![0], count: Int(chunk.buffer.frameLength))
        }
        return samples
    }

    func testNewFormatsAreImportedAndOnlySynthesizedFormatsStayUnsupported() {
        for ext in ["ogg", "oga", "spx", "ape", "wv", "wma", "dsf", "dff", "mka", "webm", "mpc", "tta", "tak", "shn"] {
            XCTAssertTrue(MetadataReader.supportedExtensions.contains(ext), ext)
            XCTAssertFalse(MetadataReader.knownUnsupported.contains(ext), ext)
        }
        for ext in ["mid", "midi", "xm", "mod"] { XCTAssertTrue(MetadataReader.knownUnsupported.contains(ext), ext) }
    }

    func testEveryFormatDecodesToTheTone() async throws {
        // Lossless formats decode exactly; lossy codecs drop or add a few milliseconds.
        let cases: [(String, ClosedRange<Int>, Float)] = [
            ("tone.wv", 48_000...48_000, 0.0625), ("tone.tta", 48_000...48_000, 0.0625),
            ("tone.mka", 48_000...48_000, 0.0625), ("tone.ogg", 47_000...48_000, 0.0625),
            ("tone.wma", 46_500...48_100, 0.0625), ("tone.spx", 47_900...48_100, 0.0625),
            ("tone.mpc", 48_000...48_950, 0.0625), ("tone.dsf", 4_700...4_900, 0.18)
        ]
        for (name, frames, rms) in cases {
            let samples = try await decode(fixture(name))
            XCTAssertTrue(frames.contains(samples.count), "\(name): \(samples.count) frames")
            // Skip codec start-up and DSD filter settling; the rest is the sine's RMS.
            let body = samples.dropFirst(samples.count / 5).prefix(samples.count / 2)
            let measured = (body.reduce(0) { $0 + $1 * $1 } / Float(max(1, body.count))).squareRoot()
            XCTAssertEqual(measured, rms, accuracy: rms * 0.2, name)
        }
    }

    func testTagsAndCoverAreRead() async throws {
        for name in ["tags.ogg", "tags.wv", "tags.wma"] {
            let meta = try await MetadataReader.read(fixture(name))
            XCTAssertEqual(meta.title, "Tag Preservation", name)
            XCTAssertEqual(meta.artist, "Fixture Artist", name)
            XCTAssertEqual(meta.album, "Fixture Album", name)
            XCTAssertEqual(meta.albumArtist, "Fixture Album Artist", name)
            XCTAssertEqual(meta.trackNumber, 3, name)
            XCTAssertEqual(meta.discNumber, 2, name)
            XCTAssertEqual(meta.year, 2024, name)
            XCTAssertEqual(meta.genre, "Test", name)
            XCTAssertEqual(meta.duration, 1, accuracy: 0.01, name)
            XCTAssertFalse(meta.usedFallback, name)
        }
        let cover = try await MetadataReader.read(fixture("tags.ogg")).artwork
        XCTAssertEqual(cover?.prefix(4), Data([0x89, 0x50, 0x4E, 0x47]))
    }

    func testSeekingMatchesContinuousDecoding() async throws {
        for name in ["tone.wv", "tone.ogg", "tone.mpc"] {
            let url = fixture(name)
            let full = try await decode(url)
            for start in [0.25, 0.5, 0.9] {
                let part = try await decode(url, start: start)
                let offset = full.count - part.count
                XCTAssertEqual(Double(offset), start * 48_000, accuracy: 4, "\(name) at \(start)")
                // Skip the resampler's start-up when the file isn't at 48 kHz (Musepack).
                let worst = zip(part.dropFirst(512), full[(offset + 512)...]).map { abs($0 - $1) }.max() ?? 1
                XCTAssertLessThan(worst, 0.002, "\(name) at \(start)")
            }
        }
    }

    func testReplaceArtworkKeepsTagsAndAudio() async throws {
        let artwork = try EmbeddedArtwork.prepare(solidPNG())
        for name in ["tags.ogg", "tags.wv", "tags.wma", "tone.tta", "tone.dsf"] {
            let url = try copy(name)
            let before = try await MetadataReader.read(url)
            let audio = try await decode(url)
            do { try ArtworkTagWriter.replaceFile(at: url, artwork: artwork) }
            catch { XCTFail("\(name): \(error.localizedDescription)"); continue }
            let after = try await MetadataReader.read(url)
            XCTAssertEqual(after.artwork, artwork.data, name)
            XCTAssertEqual(after.title, before.title, name)
            XCTAssertEqual(after.artist, before.artist, name)
            XCTAssertEqual(after.album, before.album, name)
            XCTAssertEqual(after.albumArtist, before.albumArtist, name)
            XCTAssertEqual(after.trackNumber, before.trackNumber, name)
            XCTAssertEqual(after.year, before.year, name)
            let decoded = try await decode(url)
            XCTAssertEqual(decoded, audio, "Audio changed in \(name)")
        }
    }

    private func solidPNG() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 0.7, green: 0.2, blue: 0.4, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }
}
