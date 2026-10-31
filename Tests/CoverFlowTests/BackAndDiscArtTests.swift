import XCTest
import AppKit
@testable import CoverFlow

final class BackAndDiscArtTests: XCTestCase {
    private func makeFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BackAndDiscArtTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A small solid PNG.
    private func png(_ color: NSColor, width: Int = 8, height: Int = 8) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    private func fixture(_ name: String) -> URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures/" + name)
    }

    func testFolderImageNamesAreRecognised() {
        XCTAssertEqual(ExtraArtworkReader.classify(fileName: "back.jpg")?.kind, .back)
        XCTAssertEqual(ExtraArtworkReader.classify(fileName: "Back Cover.PNG")?.kind, .back)
        XCTAssertEqual(ExtraArtworkReader.classify(fileName: "inlay.jpeg")?.kind, .back)
        XCTAssertEqual(ExtraArtworkReader.classify(fileName: "cd.jpg")?.kind, .disc)
        XCTAssertNil(ExtraArtworkReader.classify(fileName: "cd.jpg")?.disc)
        XCTAssertEqual(ExtraArtworkReader.classify(fileName: "CD2.png")?.disc, 2)
        XCTAssertEqual(ExtraArtworkReader.classify(fileName: "disc 3.jpg")?.disc, 3)
        XCTAssertEqual(ExtraArtworkReader.classify(fileName: "vinyl_1.webp")?.disc, 1)
        XCTAssertNil(ExtraArtworkReader.classify(fileName: "cover.jpg"))
        XCTAssertNil(ExtraArtworkReader.classify(fileName: "back.txt"))
        XCTAssertNil(ExtraArtworkReader.classify(fileName: "backstage.jpg"))
    }

    func testCoverArtArchiveIndexGivesBackAndNumberedDiscsFromTrustedHostsOnly() throws {
        let json = """
        {"images":[
         {"types":["Front"],"front":true,"back":false,"image":"http://coverartarchive.org/release/r/1.jpg","thumbnails":{"1200":"http://coverartarchive.org/release/r/1-1200.jpg"},"comment":""},
         {"types":["Back"],"front":false,"back":true,"image":"http://coverartarchive.org/release/r/2.jpg","thumbnails":{"1200":"http://coverartarchive.org/release/r/2-1200.jpg"},"comment":""},
         {"types":["Medium"],"front":false,"back":false,"image":"http://coverartarchive.org/release/r/4.jpg","thumbnails":{"large":"http://coverartarchive.org/release/r/4-500.jpg"},"comment":"CD 2"},
         {"types":["Medium"],"front":false,"back":false,"image":"http://coverartarchive.org/release/r/3.jpg","thumbnails":{},"comment":"disc"},
         {"types":["Medium"],"image":"https://evil.example.com/x.jpg","comment":""},
         {"types":["Booklet"],"image":"http://coverartarchive.org/release/r/5.jpg"}
        ],"release":"https://musicbrainz.org/release/r"}
        """
        let extras = try MusicLookupClient.parseCoverExtras(Data(json.utf8))
        XCTAssertEqual(extras.count, 3)
        XCTAssertEqual(extras[0], CoverArtExtra(kind: .back, disc: nil, url: URL(string: "https://coverartarchive.org/release/r/2-1200.jpg")!))
        XCTAssertEqual(extras[1].disc, 2)
        XCTAssertEqual(extras[1].url.absoluteString, "https://coverartarchive.org/release/r/4-500.jpg")
        XCTAssertEqual(extras[2].disc, 3)
        XCTAssertThrowsError(try MusicLookupClient.parseCoverExtras(Data("nope".utf8)))
    }

    func testUnnumberedDiscArtBelongsToTheTracksDiscAndFilesBeatEmbeddedPictures() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let audio = folder.appendingPathComponent("song.flac")
        try FileManager.default.copyItem(at: fixture("tags.flac"), to: audio)
        try png(.red).write(to: folder.appendingPathComponent("back.jpg"))
        try png(.blue).write(to: folder.appendingPathComponent("Back.png"))      // second back is ignored
        try png(.green).write(to: folder.appendingPathComponent("cd.png"))

        let found = ExtraArtworkReader.read(for: audio, trackDisc: 2)

        XCTAssertEqual(found.filter { $0.kind == .back }.count, 1)
        XCTAssertEqual(found.first { $0.kind == .disc }?.disc, 2)
        // The fixture has no back/media pictures embedded, and reading it must not fail.
        XCTAssertTrue(ExtraArtworkReader.embeddedImages(for: audio).isEmpty)
    }

    func testExtrasAreNamedApartFromTheFrontCoverAndSurviveANewFrontCover() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ArtworkStore(directory: folder)
        let album = UUID()
        let back = try store.saveExtra(data: png(.red, width: 12, height: 10), albumID: album, kind: .back)
        let disc = try store.saveExtra(data: png(.green), albumID: album, kind: .disc, disc: 2)
        XCTAssertTrue(back.file.hasPrefix(album.uuidString + "_back-"))
        XCTAssertTrue(disc.file.hasPrefix(album.uuidString + "_disc2-"))
        XCTAssertEqual(disc.disc, 2)
        XCTAssertNil(back.disc)
        XCTAssertEqual([back.pixelWidth, back.pixelHeight], [12, 10])

        _ = try store.save(data: png(.blue), albumID: album)                     // a new front cover
        _ = try store.save(data: png(.white), albumID: album)                    // replaces the old front only
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(album.uuidString) }
        XCTAssertEqual(names.count, 3)
        XCTAssertTrue(names.contains(back.file) && names.contains(disc.file))

        store.removeExtras([back])
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(back.file).path))
        XCTAssertThrowsError(try store.saveExtra(data: Data("not an image".utf8), albumID: album, kind: .back))
    }

    func testLibrariesWithoutExtraImagesStillDecodeAndExtrasRoundTrip() throws {
        let json = """
        {"id":"6E1C4D7A-6C3F-4C55-9E77-2B0E1B7C8E11","groupKey":"g","title":"T","artist":"A","trackIDs":[],
         "artworkVersion":0,"dateAdded":0,"isDemo":false,"missingMetadata":false,"userEdited":false}
        """
        var album = try JSONDecoder().decode(Album.self, from: Data(json.utf8))
        XCTAssertNil(album.extraImages)
        XCTAssertFalse(album.hasExtraImages)
        album.extraImages = [AlbumImage(kind: .disc, file: "d2", disc: 2, pixelWidth: 1, pixelHeight: 1),
                             AlbumImage(kind: .back, file: "b", disc: nil, pixelWidth: 1, pixelHeight: 1),
                             AlbumImage(kind: .disc, file: "d1", disc: 1, pixelWidth: 1, pixelHeight: 1)]
        let decoded = try JSONDecoder().decode(Album.self, from: JSONEncoder().encode(album))
        XCTAssertEqual(decoded, album)
        XCTAssertEqual(decoded.backImage?.file, "b")
        XCTAssertEqual(decoded.discImages.map(\.file), ["d1", "d2"])
    }

    @MainActor
    func testImportPicksUpFolderArtAndRemovingTheAlbumDeletesIt() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let music = root.appendingPathComponent("Music", isDirectory: true)
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture("tags.flac"), to: music.appendingPathComponent("03 song.flac"))
        try png(.red).write(to: music.appendingPathComponent("back.png"))
        try png(.green).write(to: music.appendingPathComponent("cd.png"))
        let artwork = root.appendingPathComponent("Artwork", isDirectory: true)
        try FileManager.default.createDirectory(at: artwork, withIntermediateDirectories: true)
        let library = LibraryStore(artwork: ArtworkStore(directory: artwork), libraryURL: root.appendingPathComponent("Library.json"))

        library.importURLs([music])
        for _ in 0..<200 where library.importProgress != nil || library.lastReport == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let album = try XCTUnwrap(library.albums.first)
        XCTAssertNotNil(album.backImage)
        XCTAssertEqual(album.discImages.map(\.disc), [2])                       // the fixture is disc 2 of 3
        let files = (album.extraImages ?? []).map { artwork.appendingPathComponent($0.file) }
        XCTAssertTrue(files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })

        // Downloaded art replaces the same kind and disc, and keeps the rest.
        let saved = await library.replaceExtraImages(album.id, with: [(kind: .back, disc: nil, data: png(.blue))])
        XCTAssertEqual(saved, 1)
        let updated = try XCTUnwrap(library.album(album.id))
        XCTAssertEqual(updated.extraImages?.count, 2)
        XCTAssertNotEqual(updated.backImage?.file, album.backImage?.file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: artwork.appendingPathComponent(album.backImage!.file).path))

        let remaining = (updated.extraImages ?? []).map { artwork.appendingPathComponent($0.file) }
        library.removeAlbums([album.id])
        XCTAssertTrue(remaining.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
    }
}
