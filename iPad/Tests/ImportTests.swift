import XCTest

@testable import iPadSignal

final class ImportTests: XCTestCase {
  func testNestedImportFindsAllAudioAndSeparatesUnsupportedFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("Disc 2"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for name in [
      "01.MP3", "Disc 2/02.flac", "Disc 2/03.wav", "Disc 2/voice.ogg", "cover.jpg", "01.LRC",
      ".hidden.mp3",
    ] { try Data("fixture".utf8).write(to: root.appendingPathComponent(name)) }
    let result = LocalAudioImport.enumerate(
      [root, root.appendingPathComponent("01.MP3")], supported: ["mp3", "flac", "wav"],
      knownUnsupported: ["ogg"])
    XCTAssertEqual(result.audio.count, 3)
    XCTAssertEqual(result.unsupported.map(\.lastPathComponent), ["voice.ogg"])
    XCTAssertEqual(
      LocalAudioImport.enumerate(
        [root.appendingPathComponent("cover.jpg")], supported: ["mp3"], knownUnsupported: []
      ).unsupported.count, 1)
  }
  func testOwnedCopyKeepsUppercaseLyricsAndSurvivesDeletingSource() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let source = root.appendingPathComponent("source")
    let destination = root.appendingPathComponent("owned")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let track = source.appendingPathComponent("Audio café.wav")
    let lyric = source.appendingPathComponent("Audio café.LRC")
    try Data([1, 2, 3, 4]).write(to: track)
    try Data("[00:01]Hello".utf8).write(to: lyric)
    let hash = try LocalAudioImport.digest(track)
    let owned = try LocalAudioImport.copyAudio(track, to: destination)
    try FileManager.default.removeItem(at: source)
    XCTAssertEqual(try LocalAudioImport.digest(owned), hash)
    XCTAssertEqual(
      try String(contentsOf: owned.deletingPathExtension().appendingPathExtension("lrc")),
      "[00:01]Hello")
  }
  func testMediaLocationRebasesToCurrentContainer() throws {
    let id = UUID()
    let root = URL(fileURLWithPath: "/new-container/Media")
    XCTAssertEqual(
      LocalAudioImport.mediaURL(root: root, id: id, filename: "../../old-container/Song.wav").path,
      "/new-container/Media/\(id.uuidString)/Song.wav")
  }
}
