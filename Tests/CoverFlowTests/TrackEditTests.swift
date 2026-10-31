import XCTest
@testable import CoverFlow

final class TrackEditTests: XCTestCase {
    private struct Snapshot: Codable {
        var version = 1
        var albums: [Album]
        var tracks: [Track]
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TrackEditTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func track(_ title: String, number: Int, folder: URL) throws -> Track {
        let url = folder.appendingPathComponent(title + ".mp3")
        try Data("original \(title)".utf8).write(to: url)
        return Track(id: UUID(), fileURL: url, title: title, artist: "Artist", albumTitle: "Album",
                     trackNumber: number, duration: 120, dateAdded: Date(), isDemo: false,
                     missingMetadata: true, fingerprint: title)
    }

    @MainActor
    private func library(_ folder: URL, tracks: [Track], userEdited: Bool = false) throws -> (LibraryStore, Album) {
        let album = Album(id: UUID(), groupKey: "g", title: "Album", artist: "Artist",
                          trackIDs: tracks.map(\.id), artworkFile: nil, artworkVersion: 0,
                          dateAdded: Date(), isDemo: false, missingMetadata: false, userEdited: userEdited)
        let url = folder.appendingPathComponent("Library.json")
        try JSONEncoder().encode(Snapshot(albums: [album], tracks: tracks)).write(to: url)
        let store = LibraryStore(artwork: ArtworkStore(directory: folder), libraryURL: url)
        store.load()
        return (store, album)
    }

    @MainActor
    func testEditingOneTrackUpdatesItReordersTheAlbumAndPersists() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try track("First", number: 1, folder: folder)
        let second = try track("Second", number: 2, folder: folder)
        let (library, album) = try library(folder, tracks: [first, second])

        library.updateTrack(first.id, title: "  Renamed  ", artist: "Artist", trackNumber: "3", discNumber: "",
                            year: "1997", genre: "Britpop")

        let edited = try XCTUnwrap(library.track(first.id))
        XCTAssertEqual(edited.title, "Renamed")
        XCTAssertEqual(edited.trackNumber, 3)
        XCTAssertNil(edited.discNumber)
        XCTAssertEqual(edited.year, 1997)
        XCTAssertEqual(edited.genre, "Britpop")
        XCTAssertFalse(edited.missingMetadata)
        XCTAssertEqual(edited.fingerprint, first.fingerprint)          // re-imports are still recognised
        XCTAssertEqual(edited.fileURL, first.fileURL)
        XCTAssertEqual(try Data(contentsOf: first.fileURL), Data("original First".utf8))   // file untouched
        XCTAssertEqual(library.album(album.id)?.trackIDs, [second.id, first.id])           // re-sorted by number

        library.saveNow()
        let reloaded = LibraryStore(artwork: library.artwork, libraryURL: folder.appendingPathComponent("Library.json"))
        reloaded.load()
        XCTAssertEqual(reloaded.track(first.id)?.title, "Renamed")
        XCTAssertEqual(reloaded.album(album.id)?.trackIDs, [second.id, first.id])
    }

    @MainActor
    func testEmptyTitleKeepsTheOldOneAndBadNumbersAreCleared() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let only = try track("Only", number: 4, folder: folder)
        let (library, _) = try library(folder, tracks: [only])

        library.updateTrack(only.id, title: "   ", artist: "", trackNumber: "four", discNumber: "0", year: "", genre: " ")

        let edited = try XCTUnwrap(library.track(only.id))
        XCTAssertEqual(edited.title, "Only")
        XCTAssertEqual(edited.artist, "Artist")
        XCTAssertNil(edited.trackNumber)
        XCTAssertNil(edited.discNumber)
        XCTAssertNil(edited.year)
        XCTAssertNil(edited.genre)
    }

    @MainActor
    func testChangingAnArtistSettlesTheAlbumArtistUnlessTheAlbumWasEdited() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = try track("A", number: 1, folder: folder)
        let b = try track("B", number: 2, folder: folder)
        let (library, album) = try library(folder, tracks: [a, b])
        library.updateTrack(b.id, title: "B", artist: "Guest", trackNumber: "2", discNumber: "", year: "", genre: "")
        XCTAssertEqual(library.album(album.id)?.artist, "Various Artists")

        let folder2 = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder2) }
        let c = try track("C", number: 1, folder: folder2)
        let d = try track("D", number: 2, folder: folder2)
        let (edited, album2) = try self.library(folder2, tracks: [c, d], userEdited: true)
        edited.updateTrack(d.id, title: "D", artist: "Guest", trackNumber: "2", discNumber: "", year: "", genre: "")
        XCTAssertEqual(edited.album(album2.id)?.artist, "Artist")
    }

    @MainActor
    func testUnknownTrackIsIgnored() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let only = try track("Only", number: 1, folder: folder)
        let (library, _) = try library(folder, tracks: [only])
        library.updateTrack(UUID(), title: "X", artist: "Y", trackNumber: "1", discNumber: "1", year: "2000", genre: "Z")
        XCTAssertEqual(library.track(only.id)?.title, "Only")
    }
}
