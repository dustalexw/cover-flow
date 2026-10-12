import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import CoverFlow

final class ArtworkTagWriterTests: XCTestCase {
    private var directory: URL!
    private let fixtures = ["tags.mp3", "tags-aac.m4a", "tags-alac.m4a", "tags.flac", "tags.wav", "tags.aiff"]

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func copy(_ name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try FileManager.default.copyItem(at: Bundle.module.resourceURL!.appendingPathComponent("Fixtures/" + name), to: url)
        return url
    }

    private func cover(_ value: UInt8, type: UTType = .png) throws -> Data {
        var pixels = ScenePixels(width: 32, height: 32)
        for i in stride(from: 0, to: pixels.bytes.count, by: 4) {
            pixels.bytes[i] = value
            pixels.bytes[i + 1] = 120
            pixels.bytes[i + 2] = 60
        }
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(pixels.image), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    func testRoundTripReplacesCoverWithoutChangingAudioOrExistingTags() async throws {
        let first = try EmbeddedArtwork.prepare(cover(180))
        let second = try EmbeddedArtwork.prepare(cover(40))
        for name in fixtures {
            let url = try copy(name)
            let original = try Data(contentsOf: url)
            let audio = try audioPayload(original, extension: url.pathExtension)
            let metadata = try await MetadataReader.read(url)
            do { try ArtworkTagWriter.replaceFile(at: url, artwork: first) }
            catch { XCTFail("\(name): \(error.localizedDescription)"); continue }
            let firstRead = try await MetadataReader.read(url)
            XCTAssertEqual(firstRead.artwork, first.data, name)
            do { try ArtworkTagWriter.replaceFile(at: url, artwork: second) }
            catch { XCTFail("\(name): \(error.localizedDescription)"); continue }
            let result = try await MetadataReader.read(url)
            XCTAssertEqual(result.artwork, second.data, name)
            XCTAssertEqual(result.title, metadata.title, name)
            XCTAssertEqual(result.artist, metadata.artist, name)
            if metadata.album != nil { XCTAssertEqual(result.album, metadata.album, name) }
            XCTAssertEqual(result.albumArtist, metadata.albumArtist, name)
            if metadata.trackNumber != nil { XCTAssertEqual(result.trackNumber, metadata.trackNumber, name) }
            XCTAssertEqual(result.discNumber, metadata.discNumber, name)
            if metadata.year != nil { XCTAssertEqual(result.year, metadata.year, name) }
            if metadata.genre != nil { XCTAssertEqual(result.genre, metadata.genre, name) }
            let updated = try Data(contentsOf: url)
            XCTAssertEqual(try audioPayload(updated, extension: url.pathExtension), audio, name)
            XCTAssertNil(updated.range(of: first.data), "Old front cover retained in \(name)")
            XCTAssertNotNil(updated.range(of: second.data), name)
        }
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".coverflow-") })
    }

    func testFailuresKeepOriginalBytesAndReportEachFileWhileDeduplicatingAliases() async throws {
        let good = try copy("tags.mp3")
        let locked = try copy("tags.flac")
        let original = try Data(contentsOf: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
        let unsupported = directory.appendingPathComponent("unsupported.caf")
        try Data("Keep me".utf8).write(to: unsupported)
        let corrupt = directory.appendingPathComponent("corrupt.m4a")
        try Data("Not an audio file".utf8).write(to: corrupt)
        let alias = directory.appendingPathComponent("alias.mp3")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: good)
        let report = await ArtworkTagWriter.shared.embed(try EmbeddedArtwork.prepare(cover(120)), in:
            [good, alias, locked, unsupported, corrupt, directory.appendingPathComponent("missing.mp3")])
        XCTAssertEqual(report.updated, 1)
        XCTAssertEqual(report.failures.count, 4)
        XCTAssertEqual(try Data(contentsOf: locked), original)
        XCTAssertEqual(try String(contentsOf: unsupported), "Keep me")
        XCTAssertEqual(try String(contentsOf: corrupt), "Not an audio file")
        XCTAssertTrue(try alias.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".coverflow-") })
    }

    func testImageConversionMakesNonstandardArtworkReadableByTagConsumers() throws {
        let png = try cover(100)
        XCTAssertEqual(try EmbeddedArtwork.prepare(png).data, png)
        let tiff = try EmbeddedArtwork.prepare(cover(100, type: .tiff))
        XCTAssertEqual(tiff.mimeType, "image/jpeg")
        XCTAssertEqual(tiff.width, 32)
        XCTAssertEqual(tiff.height, 32)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(tiff.data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
        XCTAssertThrowsError(try EmbeddedArtwork.prepare(Data("Invalid image".utf8)))
    }

    func testUntaggedAndID3v1OnlyMP3FilesGainACoverWithoutLosingLegacyText() async throws {
        let original = try Data(contentsOf: copy("tags.mp3"))
        let audio = try audioPayload(original, extension: "mp3")
        let artwork = try EmbeddedArtwork.prepare(cover(90))
        for legacy in [false, true] {
            let url = directory.appendingPathComponent(legacy ? "legacy.mp3" : "untagged.mp3")
            var data = audio
            var id3v1 = Data(repeating: 0, count: 128)
            id3v1.replaceSubrange(0..<3, with: Data("TAG".utf8))
            id3v1.replaceSubrange(3..<3+12, with: Data("Legacy Title".utf8))
            id3v1.replaceSubrange(33..<33+13, with: Data("Legacy Artist".utf8))
            id3v1[127] = 17
            if legacy { data.append(id3v1) }
            try data.write(to: url)
            try ArtworkTagWriter.replaceFile(at: url, artwork: artwork)
            let updated = try Data(contentsOf: url)
            XCTAssertEqual(try audioPayload(updated, extension: "mp3"), audio)
            let metadata = try await MetadataReader.read(url)
            XCTAssertEqual(metadata.artwork, artwork.data)
            if legacy {
                XCTAssertEqual(metadata.title, "Legacy Title")
                XCTAssertEqual(metadata.artist, "Legacy Artist")
                XCTAssertEqual(updated.suffix(128), id3v1)
            }
        }
    }

    func testFLACReplacementKeepsLabelledBackCover() async throws {
        let url = try copy("tags.flac")
        let back = try cover(210)
        let front = try EmbeddedArtwork.prepare(cover(30))
        var data = try Data(contentsOf: url)
        var offset = 4
        while true {
            let last = data[offset] & 0x80 != 0
            let size = Int(data[offset + 1]) << 16 | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
            if last { data[offset] &= 0x7f }
            offset += 4 + size
            if last { break }
        }
        func be(_ value: Int) -> Data { Data([UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)]) }
        var picture = be(4) // FLAC picture type 4: back cover
        picture.append(be(9)); picture.append(Data("image/png".utf8))
        picture.append(be(0))
        for value in [32, 32, 32, 0, back.count] { picture.append(be(value)) }
        picture.append(back)
        var block = be(picture.count); block[0] = 0x86; block.append(picture)
        data.insert(contentsOf: block, at: offset)
        try data.write(to: url)
        try ArtworkTagWriter.replaceFile(at: url, artwork: front)
        let updated = try Data(contentsOf: url)
        XCTAssertNotNil(updated.range(of: back))
        XCTAssertEqual(try audioPayload(updated, extension: "flac"), try audioPayload(data, extension: "flac"))
        let metadata = try await MetadataReader.read(url)
        XCTAssertEqual(metadata.artwork, front.data)
    }

    // Compare the encoded audio payload itself: this catches recompression, not just
    // an unchanged duration or a decoder that happens to sound the same.
    private func audioPayload(_ data: Data, extension ext: String) throws -> Data {
        let bytes = [UInt8](data)
        func integer(_ offset: Int, _ count: Int, little: Bool = false) -> Int {
            let values = bytes[offset..<(offset + count)]
            return (little ? Array(values.reversed()) : Array(values)).reduce(0) { ($0 << 8) | Int($1) }
        }
        func text(_ offset: Int, _ count: Int) -> String { String(decoding: bytes[offset..<(offset + count)], as: UTF8.self) }
        switch ext {
        case "mp3":
            var start = 0
            if text(0, 3) == "ID3" { start = 10 + bytes[6..<10].reduce(0) { ($0 << 7) | Int($1 & 0x7f) } }
            var end = bytes.count
            if end >= 128 && text(end - 128, 3) == "TAG" { end -= 128 }
            return data.subdata(in: start..<end)
        case "flac":
            var offset = 4
            while true {
                let last = bytes[offset] & 0x80 != 0
                offset += 4 + integer(offset + 1, 3)
                if last { return data.subdata(in: offset..<data.count) }
            }
        case "m4a":
            var offset = 0
            while offset + 8 <= bytes.count {
                var size = integer(offset, 4)
                var header = 8
                if size == 1 { size = integer(offset + 8, 8); header = 16 }
                if size == 0 { size = bytes.count - offset }
                if text(offset + 4, 4) == "mdat" { return data.subdata(in: (offset + header)..<(offset + size)) }
                guard size >= header else { break }
                offset += size
            }
        case "wav", "aiff":
            var offset = 12
            while offset + 8 <= bytes.count {
                let size = integer(offset + 4, 4, little: ext == "wav")
                if text(offset, 4) == (ext == "wav" ? "data" : "SSND") {
                    return data.subdata(in: (offset + 8)..<(offset + 8 + size))
                }
                offset += 8 + size + size % 2
            }
        default: break
        }
        throw ArtworkTagError(message: "Missing audio payload in test fixture.")
    }
}
