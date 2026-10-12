import XCTest
@testable import CoverFlow

final class LyricsTests: XCTestCase {
    func testMultipleTagsFractionsTranslationsAndStableOrdering() {
        let lyrics = LyricsDocument.parse("""
        [ar:Artist]
        [ti:Song]
        [00:12.345]Later line
        [00:01.2][00:20.20]Repeated line
        [00:01.20]Translation
        [00:01.2]Repeated line
        [00:04:50]Legacy fraction
        [01:00]Final minute
        """)
        XCTAssertEqual(lyrics.cues.map(\.time), [1.2, 4.5, 12.345, 20.2, 60])
        XCTAssertEqual(lyrics.cues.map(\.text), ["Repeated line\nTranslation", "Legacy fraction", "Later line", "Repeated line", "Final minute"])
        XCTAssertTrue(lyrics.isSynced)
        XCTAssertNil(lyrics.activeIndex(at: 1.19))
        XCTAssertEqual(lyrics.activeIndex(at: 1.2), 0)
        XCTAssertEqual(lyrics.activeIndex(at: 12.345), 2)
        XCTAssertEqual(lyrics.activeIndex(at: 500), 4)
    }

    func testOffsetsBlankBreaksAndBackwardSeeks() throws {
        let lyrics = LyricsDocument.parse("[00:02]First\n[00:04]\n[00:06]Last\n[offset:+500]")
        XCTAssertEqual(lyrics.activeIndex(at: 1.5), 0)
        XCTAssertEqual(lyrics.activeIndex(at: 3.5), 1)
        XCTAssertEqual(lyrics.cues[1].text, "")
        XCTAssertEqual(lyrics.activeIndex(at: 5.5), 2)
        XCTAssertEqual(lyrics.activeIndex(at: 2), 0)
        XCTAssertNil(lyrics.activeIndex(at: .nan))
        XCTAssertEqual(lyrics.playbackTime(for: lyrics.cues[2]), 5.5)
        let delayed = LyricsDocument.parse("[offset:-1000]\n[00:02]Later")
        XCTAssertNil(delayed.activeIndex(at: 2.99))
        XCTAssertEqual(delayed.activeIndex(at: 3), 0)
        XCTAssertEqual(delayed.playbackTime(for: delayed.cues[0]), 3)
    }

    func testUnicodeEnhancedWordTagsAndMalformedLines() {
        let lyrics = LyricsDocument.parse("\u{FEFF}[00:02.10]<00:02.10>Hello <00:02.50>世界 🎵\r\n[00:75]Invalid\r\n[00:03]Keep [00:04] in text\r\n[offset:NaN]")
        XCTAssertEqual(lyrics.cues.count, 2)
        XCTAssertEqual(lyrics.cues[0].text, "Hello 世界 🎵")
        XCTAssertEqual(lyrics.cues[1].text, "Keep [00:04] in text")
        XCTAssertEqual(lyrics.offset, 0)
        let plain = LyricsDocument.parse("[ar:Artist]\nFirst verse\n\nSecond verse\n")
        XCTAssertFalse(plain.isSynced)
        XCTAssertEqual(plain.plainText, "First verse\n\nSecond verse")
        XCTAssertTrue(LyricsDocument.parse("[ar:Artist]\n[offset:0]").isEmpty)
    }

    func testAutomaticSidecarAndImportedCopySurviveRestartWithoutChangingOriginal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("01 Song.flac")
        let sidecar = root.appendingPathComponent("01 Song.LRC")
        let directory = root.appendingPathComponent("Saved Lyrics")
        let id = UUID()
        XCTAssertNil(try LyricsStore.find(trackID: id, audioURL: audio, directory: directory))
        let original = Data("[00:01]Sidecar lyric".utf8)
        try original.write(to: sidecar)
        let automatic = try XCTUnwrap(LyricsStore.find(trackID: id, audioURL: audio, directory: directory))
        XCTAssertFalse(automatic.imported)
        XCTAssertEqual(automatic.document.cues[0].text, "Sidecar lyric")
        let chosen = root.appendingPathComponent("Chosen.lrc")
        try Data("[00:02]Imported lyric".utf8).write(to: chosen)
        _ = try LyricsStore.importFile(chosen, trackID: id, directory: directory)
        try FileManager.default.removeItem(at: chosen)
        let restored = try XCTUnwrap(LyricsStore.find(trackID: id, audioURL: audio, directory: directory))
        XCTAssertTrue(restored.imported)
        XCTAssertEqual(restored.document.cues[0].text, "Imported lyric")
        XCTAssertEqual(try Data(contentsOf: sidecar), original)
        // Files are associated with one track, never every track in the album.
        XCTAssertNil(try LyricsStore.find(trackID: UUID(), audioURL: root.appendingPathComponent("Other.flac"), directory: directory))
    }

    func testUTF16ReloadAndFailedImportsDoNotOverwriteSavedLyrics() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let chosen = root.appendingPathComponent("Song.lrc")
        let directory = root.appendingPathComponent("Imported")
        let id = UUID()
        try XCTUnwrap("[00:01]Bonjour 世界".data(using: .utf16)).write(to: chosen)
        _ = try LyricsStore.importFile(chosen, trackID: id, directory: directory)
        XCTAssertEqual(try LyricsStore.read(directory.appendingPathComponent(id.uuidString + ".lrc")).cues[0].text, "Bonjour 世界")
        try Data("[ar:Empty]".utf8).write(to: chosen)
        XCTAssertThrowsError(try LyricsStore.importFile(chosen, trackID: id, directory: directory))
        XCTAssertEqual(try LyricsStore.read(directory.appendingPathComponent(id.uuidString + ".lrc")).cues[0].text, "Bonjour 世界")
        try Data(repeating: 65, count: 2 * 1024 * 1024 + 1).write(to: chosen)
        XCTAssertThrowsError(try LyricsStore.read(chosen))
        let wrong = root.appendingPathComponent("Wrong.png")
        XCTAssertThrowsError(try LyricsStore.importFile(wrong, trackID: id, directory: directory))
    }

    @MainActor
    func testChangingTrackClearsPriorLyricsAndReloadReadsEditedSidecar() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Song.wav")
        let sidecar = root.appendingPathComponent("Song.lrc")
        var track = Track(id: UUID(), fileURL: url, title: "Song", artist: "Artist", albumTitle: "Record",
            albumArtist: nil, trackNumber: 1, discNumber: nil, duration: 10, year: nil, genre: nil,
            dateAdded: Date(), isDemo: false, missingMetadata: false, fingerprint: "test")
        let store = LyricsStore(directory: root.appendingPathComponent("Imported"))
        try Data("[00:01]Original".utf8).write(to: sidecar)
        await store.load(track: track)
        XCTAssertEqual(store.loaded?.document.cues[0].text, "Original")
        try Data("[00:02]Edited".utf8).write(to: sidecar)
        await store.load(track: track)
        XCTAssertEqual(store.loaded?.document.cues[0].text, "Edited")
        track.fileURL = root.appendingPathComponent("Other.wav")
        await store.load(track: track)
        XCTAssertNil(store.loaded)
        XCTAssertFalse(store.loading)
        await store.load(track: nil)
        XCTAssertNil(store.trackID)
    }
}
