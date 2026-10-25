import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import CoverFlow

/// The Opus fixtures are one second of a 440 Hz sine at ffmpeg's default amplitude of
/// 1/8: tone.opus and tags.opus are stereo with 20 ms packets, lowered 3 dB by ffmpeg's
/// mono-to-stereo upmix when they were made; tone-mono.opus is mono with 60 ms packets. tags.opus also carries Vorbis comments and an 8×8 PNG front cover.
final class OpusTests: XCTestCase {
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

    private func decode(_ url: URL, start: Double = 0) async throws -> [Float] {
        let decoder = try PCMDecoder(url: url, start: start)
        var samples: [Float] = []
        while let chunk = try await decoder.read() {
            samples += UnsafeBufferPointer(start: chunk.buffer.floatChannelData![1], count: Int(chunk.buffer.frameLength))
        }
        return samples
    }

    func testStreamHeadersGiveExactLengthAfterPreSkipAndEndTrim() throws {
        for name in ["tone.opus", "tone-mono.opus", "tags.opus"] {
            let stream = try OggOpusStream(url: fixture(name))
            XCTAssertEqual(stream.head.preSkip, 312, name)
            XCTAssertEqual(stream.length, 48_000, name)
            XCTAssertEqual(stream.duration, 1, accuracy: 0.000_1, name)
        }
        XCTAssertEqual(try OggOpusStream(url: fixture("tone-mono.opus")).head.channels, 1)
        XCTAssertEqual(OpusPacket.sampleCount([0xF8]), 960)          // CELT 20 ms, one frame
        XCTAssertEqual(OpusPacket.sampleCount([0x1B, 0x02]), 5_760)  // SILK 60 ms, two frames
        XCTAssertNil(OpusPacket.sampleCount([0x1B, 0x03]))           // 180 ms exceeds the limit
    }

    func testMetadataComesFromOpusTags() async throws {
        let meta = try await MetadataReader.read(fixture("tags.opus"))
        XCTAssertEqual(meta.title, "Tag Preservation")
        XCTAssertEqual(meta.artist, "Fixture Artist")
        XCTAssertEqual(meta.album, "Fixture Album")
        XCTAssertEqual(meta.albumArtist, "Fixture Album Artist")
        XCTAssertEqual(meta.trackNumber, 3)
        XCTAssertEqual(meta.discNumber, 2)
        XCTAssertEqual(meta.year, 2024)
        XCTAssertEqual(meta.genre, "Test")
        XCTAssertEqual(meta.duration, 1, accuracy: 0.000_1)
        XCTAssertFalse(meta.usedFallback)
        let artwork = try XCTUnwrap(meta.artwork)
        XCTAssertEqual(artwork.prefix(8), Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
    }

    func testOggWithoutOpusIsReportedAsNotPlayable() async throws {
        // One beginning-of-stream page holding a Vorbis identification packet.
        var page = Data("OggS".utf8) + Data([0, 0x02]) + Data(count: 8) + Data([1, 0, 0, 0]) + Data(count: 8)
        page += Data([1, 30]) + Data([1]) + Data("vorbis".utf8) + Data(count: 23)
        let url = directory.appendingPathComponent("vorbis.ogg")
        try page.write(to: url)
        do {
            _ = try await MetadataReader.read(url)
            XCTFail("A Vorbis stream must not import as Opus")
        } catch MetadataError.notPlayable {}
        XCTAssertThrowsError(try OggOpusStream(url: url)) { XCTAssertEqual($0 as? OggOpusError, .notOpus) }
    }

    func testDecodedOpusIsTrimmedAndAlignedWithTheSource() async throws {
        try requireOpusDecoder()
        for (name, amplitude) in [("tone.opus", 0.125 / 2.0.squareRoot()), ("tone-mono.opus", 0.125)] {
            let samples = try await decode(fixture(name))
            XCTAssertEqual(samples.count, 48_000, name)
            // Aligned output differs from the source by about 0.0005 RMS; a misplaced
            // pre-skip (312) or decoder delay (120 samples) gives 0.039 or more.
            var error: Float = 0
            for n in 2_400..<45_600 {
                let expected = Float(amplitude * sin(2 * Double.pi * 440 * Double(n) / 48_000))
                error += (samples[n] - expected) * (samples[n] - expected)
            }
            XCTAssertLessThan((error / 43_200).squareRoot(), 0.005, name)
        }
    }

    func testSeekingMatchesContinuousDecoding() async throws {
        try requireOpusDecoder()
        let url = fixture("tone.opus")
        let full = try await decode(url)
        // tone.opus has 100 ms Ogg pages, so later starts resume from a page boundary.
        for start in [0.0, 0.05, 0.37, 0.5, 0.987] {
            let part = try await decode(url, start: start)
            let offset = Int(start * 48_000)
            XCTAssertEqual(part.count, 48_000 - offset, "\(start)")
            // Pre-roll lets the restarted decoder converge before the requested sample.
            let worst = zip(part, full[offset...]).map { abs($0 - $1) }.max() ?? 0
            XCTAssertLessThan(worst, 0.01, "\(start)")
        }
    }

    func testReplaceArtworkKeepsTagsAndAudioPackets() async throws {
        let url = try copy("tags.opus")
        let before = try await MetadataReader.read(url)
        let packets = audioPackets(url)
        let artwork = try EmbeddedArtwork.prepare(solidPNG())
        try ArtworkTagWriter.replaceFile(at: url, artwork: artwork)
        let after = try await MetadataReader.read(url)
        XCTAssertEqual(after.artwork, artwork.data)
        XCTAssertNotEqual(after.artwork, before.artwork)
        XCTAssertEqual(after.title, before.title)
        XCTAssertEqual(after.artist, before.artist)
        XCTAssertEqual(after.album, before.album)
        XCTAssertEqual(after.albumArtist, before.albumArtist)
        XCTAssertEqual(after.trackNumber, before.trackNumber)
        XCTAssertEqual(after.discNumber, before.discNumber)
        XCTAssertEqual(after.year, before.year)
        XCTAssertEqual(after.genre, before.genre)
        XCTAssertEqual(after.duration, before.duration)
        XCTAssertEqual(audioPackets(url), packets)
    }

    private func audioPackets(_ url: URL) -> [[UInt8]] {
        guard let stream = try? OggOpusStream(url: url) else { return [] }
        var reader = stream.packets()
        var packets: [[UInt8]] = []
        while let packet = reader.next() { packets.append(packet) }
        return packets
    }

    private func solidPNG() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.6, blue: 0.3, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func requireOpusDecoder() throws {
        var description = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatOpus, mFormatFlags: 0,
                                                      mBytesPerPacket: 0, mFramesPerPacket: 960, mBytesPerFrame: 0,
                                                      mChannelsPerFrame: 2, mBitsPerChannel: 0, mReserved: 0)
        guard let input = AVAudioFormat(streamDescription: &description),
              AVAudioConverter(from: input, to: PCMDecoder.outputFormat) != nil else {
            throw XCTSkip("The test environment has no Core Audio Opus decoder.")
        }
    }
}
