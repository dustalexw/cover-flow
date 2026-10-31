import XCTest
@testable import CoverFlow

final class MediaOrganizerTests: XCTestCase {
    private func makeFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MediaOrganizerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func item(_ source: URL, artist: String = "Oasis", album: String = "Be Here Now", title: String = "Stand by Me",
                      disc: Int? = nil, track: Int? = 5, multiDisc: Bool = false) -> MediaOrganizer.Item {
        MediaOrganizer.Item(trackID: UUID(), source: source, artist: artist, album: album, title: title,
                            discNumber: disc, trackNumber: track, multiDisc: multiDisc)
    }

    func testRelativePathUsesArtistAlbumAndNumberedTitle() {
        let src = URL(fileURLWithPath: "/Volumes/Old/whatever.FLAC")
        XCTAssertEqual(MediaOrganizer.relativePath(for: item(src)), "Oasis/Be Here Now/05 Stand by Me.flac")
        XCTAssertEqual(MediaOrganizer.relativePath(for: item(src, disc: 2, track: 3, multiDisc: true)), "Oasis/Be Here Now/2-03 Stand by Me.flac")
        XCTAssertEqual(MediaOrganizer.relativePath(for: item(src, track: nil)), "Oasis/Be Here Now/Stand by Me.flac")
    }

    func testNamesAreMadeSafeForTheFileSystem() {
        XCTAssertEqual(MediaOrganizer.sanitize("AC/DC: Live", fallback: "x"), "AC_DC_ Live")
        XCTAssertEqual(MediaOrganizer.sanitize("..hidden", fallback: "x"), "hidden")
        XCTAssertEqual(MediaOrganizer.sanitize("  spaced \n  out\t", fallback: "x"), "spaced out")
        XCTAssertEqual(MediaOrganizer.sanitize("Trailing dots...", fallback: "x"), "Trailing dots")
        XCTAssertEqual(MediaOrganizer.sanitize("   ", fallback: "Unknown Artist"), "Unknown Artist")
        XCTAssertEqual(MediaOrganizer.sanitize(String(repeating: "a", count: 300), fallback: "x").count, MediaOrganizer.maxComponentLength)
        let src = URL(fileURLWithPath: "/tmp/a.mp3")
        XCTAssertEqual(MediaOrganizer.relativePath(for: item(src, artist: "", album: "", title: "")), "Unknown Artist/Unknown Album/05 Untitled.mp3")
    }

    func testCollisionsGetNumberedIgnoringCase() {
        let folder = URL(fileURLWithPath: "/Music/Cover Flow", isDirectory: true)
        let src = URL(fileURLWithPath: "/tmp/x.mp3")
        var taken = Set<String>()
        let existing = folder.appendingPathComponent("Oasis/Be Here Now/05 Stand by Me.mp3").path.lowercased()
        let first = MediaOrganizer.destination(for: item(src), in: folder, taken: &taken, exists: { $0.path.lowercased() == existing })
        XCTAssertEqual(first.lastPathComponent, "05 Stand by Me 2.mp3")
        let second = MediaOrganizer.destination(for: item(src, title: "STAND BY ME"), in: folder, taken: &taken, exists: { _ in false })
        XCTAssertEqual(second.lastPathComponent, "05 STAND BY ME.mp3")
        let third = MediaOrganizer.destination(for: item(src), in: folder, taken: &taken, exists: { $0.path.lowercased() == existing })
        XCTAssertEqual(third.lastPathComponent, "05 Stand by Me 3.mp3")
    }

    func testCopyKeepsOriginalsAndBringsLyricsAlong() throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Downloads/track.mp3")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: source)
        try Data("[00:01]line".utf8).write(to: source.deletingPathExtension().appendingPathExtension("LRC"))
        let media = root.appendingPathComponent("Music/Cover Flow", isDirectory: true)
        let entry = item(source)

        let outcome = MediaOrganizer.perform([entry], into: media, mode: .copy)

        let target = try XCTUnwrap(outcome.moved[entry.trackID])
        XCTAssertEqual(target.path, media.appendingPathComponent("Oasis/Be Here Now/05 Stand by Me.mp3").path)
        XCTAssertEqual(try Data(contentsOf: target), Data("audio".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try String(contentsOf: target.deletingPathExtension().appendingPathExtension("lrc"), encoding: .utf8), "[00:01]line")
        XCTAssertTrue(outcome.failures.isEmpty)
    }

    func testMoveRemovesOriginalsAndSkipsFilesAlreadyInTheFolder() throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appendingPathComponent("Media", isDirectory: true)
        let outside = root.appendingPathComponent("song.flac")
        try Data("one".utf8).write(to: outside)
        let inside = media.appendingPathComponent("Someone/Something/01 Already.flac")
        try FileManager.default.createDirectory(at: inside.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("two".utf8).write(to: inside)
        let missing = root.appendingPathComponent("gone.mp3")
        let a = item(outside), b = item(inside, title: "Other"), c = item(missing, title: "Gone")

        var reported: [Int] = []
        let outcome = MediaOrganizer.perform([a, b, c], into: media, mode: .move) { done, _, _ in reported.append(done) }

        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(outcome.moved[a.trackID])), Data("one".utf8))
        XCTAssertNil(outcome.moved[b.trackID])                 // left where it is
        XCTAssertTrue(FileManager.default.fileExists(atPath: inside.path))
        XCTAssertNil(outcome.moved[c.trackID])
        XCTAssertEqual(outcome.failures.count, 1)
        XCTAssertTrue(outcome.failures[0].contains("gone.mp3"))
        XCTAssertEqual(outcome.copiedInstead, 0)
        XCTAssertEqual(reported, [0, 1, 2, 3])
    }

    func testUnavailableMediaFolderLeavesEverythingInPlace() throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("song.mp3")
        try Data("x".utf8).write(to: source)
        let blocker = root.appendingPathComponent("not-a-folder")
        try Data().write(to: blocker)                           // a file where the folder should go

        let outcome = MediaOrganizer.perform([item(source)], into: blocker.appendingPathComponent("Media"), mode: .move)

        XCTAssertTrue(outcome.moved.isEmpty)
        XCTAssertEqual(outcome.failures.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testIsInsideComparesWholePathComponents() {
        let folder = URL(fileURLWithPath: "/Users/me/Music/Cover Flow", isDirectory: true)
        XCTAssertTrue(MediaOrganizer.isInside(URL(fileURLWithPath: "/Users/me/Music/Cover Flow/A/B/c.mp3"), folder: folder))
        XCTAssertTrue(MediaOrganizer.isInside(URL(fileURLWithPath: "/users/me/music/cover flow/c.mp3"), folder: folder))
        XCTAssertFalse(MediaOrganizer.isInside(URL(fileURLWithPath: "/Users/me/Music/Cover Flow 2/c.mp3"), folder: folder))
        XCTAssertFalse(MediaOrganizer.isInside(URL(fileURLWithPath: "/Users/me/Music/c.mp3"), folder: folder))
    }
}

#if canImport(AppKit)
/// Import with "Keep media organized" on (macOS app target).
final class KeepMediaOrganizedImportTests: XCTestCase {
    private func fixture(_ name: String) -> URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures/" + name)
    }

    @MainActor
    private func importAndWait(_ library: LibraryStore, _ urls: [URL]) async throws -> ImportReport {
        library.importURLs(urls)
        for _ in 0..<200 {
            if library.importProgress == nil, let report = library.lastReport { return report }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw XCTSkip("Import did not finish in time")
    }

    @MainActor
    private func setUp(keepOrganized: Bool, mode: MediaImportMode) throws -> (root: URL, source: URL, media: URL, library: LibraryStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("KeepOrganized-\(UUID().uuidString)", isDirectory: true)
        let downloads = root.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let source = downloads.appendingPathComponent("some download.flac")
        try FileManager.default.copyItem(at: fixture("tags.flac"), to: source)
        try Data("[00:01]Hello".utf8).write(to: downloads.appendingPathComponent("some download.lrc"))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "KeepOrganized-\(UUID().uuidString)"))
        let settings = MediaLibrarySettings(defaults: defaults)
        settings.keepOrganized = keepOrganized
        settings.mode = mode
        let media = root.appendingPathComponent("Music/Cover Flow", isDirectory: true)
        settings.setFolder(media)
        let library = LibraryStore(artwork: ArtworkStore(directory: root.appendingPathComponent("Artwork", isDirectory: true)),
                                   libraryURL: root.appendingPathComponent("Library.json"), media: settings)
        return (root, source, media, library)
    }

    @MainActor
    func testMoveModeOrganizesImportsAndUpdatesTheLibrary() async throws {
        let env = try setUp(keepOrganized: true, mode: .move)
        defer { try? FileManager.default.removeItem(at: env.root) }

        let report = try await importAndWait(env.library, [env.source.deletingLastPathComponent()])

        XCTAssertEqual(report.added, 1)
        XCTAssertEqual(report.organized, 1)
        XCTAssertTrue(report.details.contains("Moved 1 file to your media folder"))
        let track = try XCTUnwrap(env.library.tracks.values.first)
        let expected = env.media.appendingPathComponent("Fixture Album Artist/Fixture Album/03 Tag Preservation.flac")
        XCTAssertEqual(track.fileURL.standardizedFileURL.path, expected.standardizedFileURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.deletingPathExtension().appendingPathExtension("lrc").path))

        // The new location is what gets saved.
        let reloaded = LibraryStore(artwork: env.library.artwork, libraryURL: env.root.appendingPathComponent("Library.json"))
        reloaded.load()
        XCTAssertEqual(reloaded.track(track.id)?.fileURL.standardizedFileURL.path, expected.standardizedFileURL.path)
        XCTAssertTrue(env.library.tracksOutsideMediaFolder().isEmpty)
    }

    @MainActor
    func testCopyModeKeepsOriginals() async throws {
        let env = try setUp(keepOrganized: true, mode: .copy)
        defer { try? FileManager.default.removeItem(at: env.root) }

        let report = try await importAndWait(env.library, [env.source])

        XCTAssertEqual(report.organized, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: env.source.path))
        let track = try XCTUnwrap(env.library.tracks.values.first)
        XCTAssertTrue(MediaOrganizer.isInside(track.fileURL, folder: env.media))
    }

    @MainActor
    func testOffLeavesFilesWhereTheyAreUntilOrganizeExistingMusic() async throws {
        let env = try setUp(keepOrganized: false, mode: .move)
        defer { try? FileManager.default.removeItem(at: env.root) }

        let report = try await importAndWait(env.library, [env.source])

        XCTAssertEqual(report.organized, 0)
        let track = try XCTUnwrap(env.library.tracks.values.first)
        XCTAssertEqual(track.fileURL.standardizedFileURL.path, env.source.standardizedFileURL.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.media.path))

        // Turning it on later and organizing the existing collection brings the file in.
        env.library.media?.keepOrganized = true
        XCTAssertEqual(env.library.tracksOutsideMediaFolder(), [track.id])
        env.library.organizeExistingLibrary()
        for _ in 0..<200 where env.library.importProgress != nil { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(MediaOrganizer.isInside(try XCTUnwrap(env.library.track(track.id)).fileURL, folder: env.media))
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.source.path))
        XCTAssertEqual(env.library.notice?.hasPrefix("Moved 1 file to"), true)
    }
}
#endif
