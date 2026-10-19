import XCTest
@testable import CoverFlow

final class TrackRemovalTests: XCTestCase {
    private struct Snapshot: Codable {
        var version = 1
        var albums: [Album]
        var tracks: [Track]
    }

    @MainActor
    func testRemovalPersistsAndNotifiesPlayerWithOnlyKnownTracks() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try track("First", number: 1, folder: folder)
        let second = try track("Second", number: 2, folder: folder)
        let other = try track("Other", number: 1, folder: folder)
        let album = makeAlbum([first, second], artwork: "cover.png")
        let untouched = makeAlbum([other])
        let cover = folder.appendingPathComponent("cover.png")
        try Data([1, 2, 3]).write(to: cover)
        let library = try library(folder, albums: [album, untouched], tracks: [first, second, other])
        var notifications: [Set<UUID>] = []
        library.onTracksRemoved = { ids in
            notifications.append(ids)
            XCTAssertNil(library.track(first.id))
            XCTAssertEqual(library.album(album.id)?.trackIDs, [second.id])
        }

        library.removeTracks([first.id, UUID()])

        XCTAssertEqual(notifications, [[first.id]])
        XCTAssertEqual(library.albumID(forTrack: second.id), album.id)
        XCTAssertNil(library.albumID(forTrack: first.id))
        XCTAssertEqual(library.album(untouched.id), untouched)
        XCTAssertEqual(library.totalDuration(library.album(album.id)!), second.duration)
        XCTAssertEqual(try Data(contentsOf: first.fileURL), Data("original First".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cover.path))
        let reloaded = LibraryStore(artwork: library.artwork, libraryURL: folder.appendingPathComponent("Library.json"))
        reloaded.load()
        XCTAssertNil(reloaded.track(first.id))
        XCTAssertEqual(reloaded.album(album.id)?.trackIDs, [second.id])
        library.removeTracks([first.id, UUID()])
        XCTAssertEqual(notifications.count, 1, "Unknown/already removed tracks must be a no-op")
        XCTAssertNil(library.notice)
    }

    @MainActor
    func testLastTrackRemovesEmptyAlbumAndArtworkButPreservesOriginalAudio() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try track("First", number: 1, folder: folder)
        let second = try track("Second", number: 1, folder: folder)
        let firstAlbum = makeAlbum([first], artwork: "first.png")
        let secondAlbum = makeAlbum([second], artwork: "second.png")
        for name in ["first.png", "second.png"] { try Data([42]).write(to: folder.appendingPathComponent(name)) }
        let library = try library(folder, albums: [firstAlbum, secondAlbum], tracks: [first, second])

        library.removeTracks([first.id, second.id])

        XCTAssertTrue(library.albums.isEmpty)
        XCTAssertTrue(library.tracks.isEmpty)
        for track in [first, second] {
            XCTAssertNil(library.albumID(forTrack: track.id))
            XCTAssertTrue(FileManager.default.fileExists(atPath: track.fileURL.path))
        }
        for name in ["first.png", "second.png"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path))
        }
        let saved = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: folder.appendingPathComponent("Library.json")))
        XCTAssertTrue(saved.tracks.isEmpty)
        XCTAssertTrue(saved.albums.isEmpty)
    }

    @MainActor
    func testRemovingOneDemoTrackOnlyDeletesItsGeneratedAudio() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var first = try track("First", number: 1, folder: folder)
        first.isDemo = true
        var second = try track("Second", number: 2, folder: folder)
        second.isDemo = true
        let album = makeAlbum([first, second])
        let library = try library(folder, albums: [album], tracks: [first, second])

        library.removeTracks([first.id])

        XCTAssertFalse(FileManager.default.fileExists(atPath: first.fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.fileURL.path))
        XCTAssertEqual(library.album(album.id)?.trackIDs, [second.id])
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func track(_ title: String, number: Int, folder: URL) throws -> Track {
        let url = folder.appendingPathComponent(title + ".mp3")
        try Data("original \(title)".utf8).write(to: url)
        return Track(id: UUID(), fileURL: url, title: title, artist: "Artist", albumTitle: "Album",
                     trackNumber: number, duration: 120, dateAdded: Date(), isDemo: false,
                     missingMetadata: false, fingerprint: title)
    }

    private func makeAlbum(_ tracks: [Track], artwork: String? = nil) -> Album {
        Album(id: UUID(), groupKey: UUID().uuidString, title: "Album", artist: "Artist",
              trackIDs: tracks.map(\.id), artworkFile: artwork, artworkVersion: 0,
              dateAdded: Date(), isDemo: tracks.allSatisfy(\.isDemo), missingMetadata: false, userEdited: false)
    }

    @MainActor
    private func library(_ folder: URL, albums: [Album], tracks: [Track]) throws -> LibraryStore {
        let url = folder.appendingPathComponent("Library.json")
        try JSONEncoder().encode(Snapshot(albums: albums, tracks: tracks)).write(to: url)
        let store = LibraryStore(artwork: ArtworkStore(directory: folder), libraryURL: url)
        store.load()
        return store
    }
}
