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
        // Common scan names, and album names that merely contain a keyword.
        XCTAssertEqual(ExtraArtworkReader.classify(fileName: "AC-DC - Back in Black - Back.jpg")?.kind, .back)
        XCTAssertNil(ExtraArtworkReader.classify(fileName: "Back in Black.jpg"))
        XCTAssertEqual(ExtraArtworkReader.classify(fileName: "cover_back.jpg")?.kind, .back)
        XCTAssertEqual(ExtraArtworkReader.classify(fileName: "Rear.png")?.kind, .back)
        XCTAssertNil(ExtraArtworkReader.classify(fileName: "Front & Back.jpg"))
        XCTAssertEqual(ExtraArtworkReader.classify(fileName: "cdart.png")?.kind, .disc)
        XCTAssertEqual(ExtraArtworkReader.classify(fileName: "Album - CD2.jpg")?.disc, 2)
        XCTAssertEqual(ExtraArtworkReader.classify(fileName: "Disc 1 Label.jpg")?.disc, 1)
        XCTAssertNil(ExtraArtworkReader.classify(fileName: "Album 2 - CD.jpg")?.disc)
        XCTAssertEqual(ExtraArtworkReader.classify(fileName: "Vinyl Side A.jpg")?.kind, .disc)
        XCTAssertNil(ExtraArtworkReader.classify(fileName: "folder.jpg"))
        XCTAssertEqual(ExtraArtworkReader.classify(fileName: "Booklet 03.jpg")?.kind, .booklet)
        XCTAssertEqual(ExtraArtworkReader.classify(fileName: "Booklet 03.jpg")?.disc, 3)
        XCTAssertEqual(ExtraArtworkReader.classify(fileName: "Liner Notes 2.png")?.disc, 2)
        XCTAssertEqual(ExtraArtworkReader.classify(fileName: "insert.jpg")?.kind, .booklet)
        XCTAssertNil(ExtraArtworkReader.classify(fileName: "Booklet Front.jpg"))
        XCTAssertEqual(ExtraArtworkReader.discFolderNumber("CD 2"), 2)
        XCTAssertNil(ExtraArtworkReader.discFolderNumber("Scans"))
    }

    func testArtworkSubfoldersAndTheAlbumFolderAboveADiscFolderAreSearched() throws {
        let album = try makeFolder()
        defer { try? FileManager.default.removeItem(at: album) }
        let disc2 = album.appendingPathComponent("CD2", isDirectory: true)
        let scans = album.appendingPathComponent("Scans", isDirectory: true)
        try FileManager.default.createDirectory(at: disc2, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scans, withIntermediateDirectories: true)
        try png(.red).write(to: scans.appendingPathComponent("Back.jpg"))
        try png(.green).write(to: scans.appendingPathComponent("CD2.png"))
        let found = ExtraArtworkReader.folderImages(for: disc2.appendingPathComponent("01.flac"), trackDisc: 2)
        XCTAssertEqual(Set(found.map { "\($0.kind.rawValue)\($0.disc ?? 0)" }), ["back0", "disc2"])
    }

    func testOtherSourcesAreParsedAndMerged() throws {
        let browse = """
        {"releases":[
         {"id":"11111111-1111-1111-1111-111111111111","cover-art-archive":{"back":false,"count":1}},
         {"id":"22222222-2222-2222-2222-222222222222","cover-art-archive":{"back":false,"count":4}},
         {"id":"33333333-3333-3333-3333-333333333333","cover-art-archive":{"back":true,"count":2}},
         {"id":"not-a-uuid","cover-art-archive":{"back":true,"count":9}}]}
        """
        XCTAssertEqual(try MusicLookupClient.parseReleaseBrowse(Data(browse.utf8)),
                       ["33333333-3333-3333-3333-333333333333", "22222222-2222-2222-2222-222222222222"])

        let audioDB = """
        {"album":[{"strAlbumBack":"https://r2.theaudiodb.com/images/media/album/back/x.jpg",
                   "strAlbumCDart":"http://r2.theaudiodb.com/images/media/album/cdart/y.png","strAlbumSpine":null}]}
        """
        let adb = try MusicLookupClient.parseAudioDB(Data(audioDB.utf8))
        XCTAssertEqual(adb.map(\.kind), [.back, .disc])
        XCTAssertEqual(adb[1].url.scheme, "https")
        XCTAssertTrue(try MusicLookupClient.parseAudioDB(Data(#"{"album":null}"#.utf8)).isEmpty)

        let group = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        let fanart = """
        {"albums":{"\(group)":{"cdart":[
          {"url":"https://assets.fanart.tv/fanart/music/a/cdart/1.png","likes":"1","disc":"1"},
          {"url":"https://assets.fanart.tv/fanart/music/a/cdart/2.png","likes":"5","disc":"1"},
          {"url":"https://assets.fanart.tv/fanart/music/a/cdart/3.png","likes":"0","disc":"2"},
          {"url":"https://evil.example.com/4.png","likes":"9","disc":"2"}]}}}
        """
        let fan = try MusicLookupClient.parseFanart(Data(fanart.utf8), releaseGroup: group)
        XCTAssertEqual(fan.map(\.disc), [1, 2])
        XCTAssertEqual(fan[0].url.lastPathComponent, "2.png")
        XCTAssertEqual(fan[1].url.lastPathComponent, "3.png")

        // Archive back scan wins; cut-out discs win unless the archive has more discs.
        let scan = { (disc: Int) in CoverArtExtra(kind: .disc, disc: disc, url: URL(string: "https://coverartarchive.org/\(disc)")!) }
        let back = CoverArtExtra(kind: .back, disc: nil, url: URL(string: "https://coverartarchive.org/b")!)
        var merged = MusicLookupClient.mergeExtras(archive: [back, scan(1)], audioDB: adb, fanart: fan)
        XCTAssertEqual(merged.map(\.source), [.coverArtArchive, .fanartTV, .fanartTV])
        merged = MusicLookupClient.mergeExtras(archive: [scan(1), scan(2), scan(3)], audioDB: adb, fanart: [])
        XCTAssertEqual(merged.map(\.source), [.theAudioDB, .coverArtArchive, .coverArtArchive, .coverArtArchive])
        XCTAssertNil(MusicLookupClient.safeURL("https://theaudiodb.com.evil.net/x.jpg"))
    }

    func testArtworkChoicesListEveryKindFromEverySource() throws {
        let index = """
        {"release":"https://musicbrainz.org/release/BBBBBBBB-0000-0000-0000-000000000000","images":[
         {"types":["Front"],"front":true,"image":"http://coverartarchive.org/release/r/1.jpg","thumbnails":{"1200":"http://coverartarchive.org/release/r/1-1200.jpg","250":"http://coverartarchive.org/release/r/1-250.jpg"},"comment":""},
         {"types":["Back"],"back":true,"image":"http://coverartarchive.org/release/r/2.jpg","thumbnails":{},"comment":"Spine side"},
         {"types":["Medium"],"image":"http://coverartarchive.org/release/r/3.jpg","comment":"CD 2"},
         {"types":["Booklet"],"image":"http://coverartarchive.org/release/r/4.jpg"}]}
        """
        XCTAssertEqual(MusicLookupClient.releaseID(inIndex: Data(index.utf8)), "bbbbbbbb-0000-0000-0000-000000000000")
        let archive = try MusicLookupClient.parseCoverCandidates(Data(index.utf8), note: "1999 · JP")
        XCTAssertEqual(archive.map(\.kind), [.front, .back, .disc, .booklet])
        XCTAssertEqual(archive[3].disc, 1)
        XCTAssertEqual(archive[0].previewURL?.absoluteString, "https://coverartarchive.org/release/r/1-250.jpg")
        XCTAssertEqual(archive[1].note, "1999 · JP · Spine side")
        XCTAssertEqual(archive[2].disc, 2)

        let browse = """
        {"releases":[{"id":"11111111-1111-1111-1111-111111111111","date":"2003-05-01","country":"GB","cover-art-archive":{"back":true,"count":3}},
                     {"id":"22222222-2222-2222-2222-222222222222","cover-art-archive":{"back":false,"count":2}}]}
        """
        let editions = try MusicLookupClient.parseEditions(Data(browse.utf8))
        XCTAssertEqual(editions.map(\.label), ["2003 · GB", "Other edition"])

        let audioDB = """
        {"album":[{"strAlbumThumbHQ":"https://r2.theaudiodb.com/a/hq.jpg","strAlbumThumb":"https://r2.theaudiodb.com/a/t.jpg",
                   "strAlbumBack":null,"strAlbumCDart":"https://r2.theaudiodb.com/a/cd.png"}]}
        """
        let adb = try MusicLookupClient.parseAudioDBCandidates(Data(audioDB.utf8))
        XCTAssertEqual(adb.map(\.kind), [.front, .front, .disc])
        XCTAssertEqual(adb[0].previewURL?.absoluteString, "https://r2.theaudiodb.com/a/hq.jpg/small")

        let group = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        let fanart = """
        {"albums":{"\(group)":{"albumcover":[{"url":"https://assets.fanart.tv/fanart/music/x/albumcover/c.jpg","likes":"2"}],
          "cdart":[{"url":"https://assets.fanart.tv/fanart/music/x/cdart/1.png","likes":"1","disc":"1"},
                   {"url":"https://assets.fanart.tv/fanart/music/x/cdart/2.png","likes":"4","disc":"2"}]}}}
        """
        let fan = try MusicLookupClient.parseFanartCandidates(Data(fanart.utf8), releaseGroup: group)
        XCTAssertEqual(fan.map(\.kind), [.front, .disc, .disc])
        XCTAssertEqual(fan[1].disc, 2)                                    // most liked first
        XCTAssertEqual(fan[1].previewURL?.absoluteString, "https://assets.fanart.tv/preview/music/x/cdart/2.png")

        // Defaults: archive front and back scan; fanart cut-outs cover more discs than scans.
        let picks = MusicLookupClient.defaultChoices(archive + adb + fan)
        XCTAssertEqual(picks.front?.source, .coverArtArchive)
        XCTAssertEqual(picks.back?.source, .coverArtArchive)
        XCTAssertEqual(picks.discs.keys.sorted(), [1, 2])
        XCTAssertTrue(picks.discs.values.allSatisfy { $0.source == .fanartTV })
        // Without fanart.tv, the archive's disc-2 scan ties TheAudioDB's disc 1; cut-outs win ties.
        XCTAssertEqual(MusicLookupClient.defaultChoices(archive + adb).discs[1]?.source, .theAudioDB)
    }

    func testBookletFoldersBecomePagesInNameOrder() throws {
        let album = try makeFolder()
        defer { try? FileManager.default.removeItem(at: album) }
        let booklet = album.appendingPathComponent("Booklet", isDirectory: true)
        try FileManager.default.createDirectory(at: booklet, withIntermediateDirectories: true)
        try png(.red).write(to: booklet.appendingPathComponent("scan10.jpg"))
        try png(.green).write(to: booklet.appendingPathComponent("scan2.jpg"))
        try png(.blue).write(to: album.appendingPathComponent("Booklet 05.png"))
        let pages = ExtraArtworkReader.folderImages(for: album.appendingPathComponent("01.flac")).filter { $0.kind == .booklet }
        XCTAssertEqual(pages.map(\.disc), [5, 1, 2])                        // numbered name first, then folder pages in order
        let store = ArtworkStore(directory: album)
        let saved = try store.saveExtra(data: png(.red), albumID: UUID(), kind: .booklet, disc: 3)
        XCTAssertTrue(saved.file.contains("_booklet3-"))
        XCTAssertEqual(saved.disc, 3)
    }

    func testSearchTitlesDropTrailingEditionNotesOnly() {
        XCTAssertEqual(MusicLookupClient.searchTitle("(What's The Story) Morning Glory? (declipped)"), "(What's The Story) Morning Glory?")
        XCTAssertEqual(MusicLookupClient.searchTitle("OK Computer [Remastered] (Deluxe Edition)"), "OK Computer")
        XCTAssertEqual(MusicLookupClient.searchTitle("(Untitled)"), "(Untitled)")
        let oasis = ArtworkMatch(id: UUID(), title: "(What’s the Story) Morning Glory?", artist: "Oasis", year: "1995")
        XCTAssertNotNil(MusicLookupClient.pickMatch([oasis], title: "(What's The Story) Morning Glory? (declipped)", artist: "Oasis"))
    }

    func testImageHostsRunInParallelWhileMetadataServicesStaySerial() {
        XCTAssertEqual(MusicLookupClient.limits(for: "musicbrainz.org").concurrent, 1)
        XCTAssertGreaterThanOrEqual(MusicLookupClient.limits(for: "musicbrainz.org").gap, 1)
        XCTAssertEqual(MusicLookupClient.limits(for: "www.theaudiodb.com").concurrent, 1)
        XCTAssertGreaterThan(MusicLookupClient.limits(for: "ia800.us.archive.org").concurrent, 1)
        XCTAssertEqual(MusicLookupClient.limits(for: "ia800.us.archive.org").gap, 0)
    }

    @MainActor
    func testRemovingOneExtraImageKeepsTheRest() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let music = root.appendingPathComponent("Music", isDirectory: true)
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture("tags.flac"), to: music.appendingPathComponent("01.flac"))
        let artwork = root.appendingPathComponent("Artwork", isDirectory: true)
        try FileManager.default.createDirectory(at: artwork, withIntermediateDirectories: true)
        let library = LibraryStore(artwork: ArtworkStore(directory: artwork), libraryURL: root.appendingPathComponent("Library.json"))
        library.importURLs([music])
        for _ in 0..<200 where library.importProgress != nil || library.lastReport == nil {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let id = try XCTUnwrap(library.albums.first?.id)
        await library.replaceExtraImages(id, with: [(kind: .back, disc: nil, data: png(.red)), (kind: .disc, disc: 1, data: png(.green)),
                                                    (kind: .disc, disc: 2, data: png(.blue))])
        library.removeExtraImages(id, only: [(kind: .disc, disc: 1)])
        let album = try XCTUnwrap(library.album(id))
        XCTAssertNotNil(album.backImage)
        XCTAssertEqual(album.discImages.map(\.disc), [2])
    }

    func testOnlyAConfidentMusicBrainzMatchIsPicked() {
        let a = ArtworkMatch(id: UUID(), title: "OK Computer", artist: "Radiohead", year: "1997")
        let b = ArtworkMatch(id: UUID(), title: "OK Computer OKNOTOK 1997 2017", artist: "Radiohead", year: "2017")
        XCTAssertEqual(MusicLookupClient.pickMatch([b, a], title: "OK Computer (Remastered)", artist: "radiohead")?.id, a.id)
        XCTAssertNil(MusicLookupClient.pickMatch([b], title: "OK Computer", artist: "Radiohead"))
        XCTAssertNil(MusicLookupClient.pickMatch([a], title: "OK Computer", artist: "Someone Else"))
        let various = ArtworkMatch(id: UUID(), title: "Now That’s What I Call Music!", artist: "Various Artists", year: "")
        XCTAssertNotNil(MusicLookupClient.pickMatch([various], title: "Now That's What I Call Music", artist: "Various Artists"))
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
