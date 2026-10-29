import XCTest

@testable import iPadSignal

final class ImportInboxTests: XCTestCase {
  private var folder: URL!
  private var inbox: ImportInbox { ImportInbox(folder: folder) }
  private let later = Date().addingTimeInterval(60)

  override func setUpWithError() throws {
    folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: folder)
  }

  func testItemsWaitUntilTheyHaveFinishedCopying() throws {
    try write("Album/01.mp3")
    try write("Loose.flac")
    try write("Loose.LRC")  // goes with Loose.flac
    try write("Not Imported/old.mp3")
    try write(".hidden.mp3")
    let now = inbox.readyItems()
    XCTAssertTrue(now.ready.isEmpty)
    XCTAssertTrue(now.stillCopying)
    let settled = inbox.readyItems(now: later)
    XCTAssertEqual(settled.ready.map(\.lastPathComponent), ["Album", "Loose.flac"])
    XCTAssertFalse(settled.stillCopying)
  }

  func testAirDropCopiesInInboxAreReadyStraightAway() throws {
    try write("Inbox/Sent.m4a")
    XCTAssertEqual(inbox.readyItems().ready.map(\.lastPathComponent), ["Sent.m4a"])
  }

  func testImportedAlbumLeavesAndFailuresAreSetAside() throws {
    let album = try write("Album/Disc 1/01.mp3").deletingLastPathComponent().deletingLastPathComponent()
    try write("Album/Disc 1/01.lrc")
    let broken = try write("Album/Disc 1/02.mp3")
    try write("Album/cover.jpg")
    let first = album.appendingPathComponent("Disc 1/01.mp3")
    inbox.finish(
      album, imported: [ImportInbox.key(first)], failed: [ImportInbox.key(broken)], unfinished: false)
    XCTAssertFalse(exists(album))
    XCTAssertTrue(exists(inbox.notImported.appendingPathComponent("Album/Disc 1/02.mp3")))
    XCTAssertFalse(exists(inbox.notImported.appendingPathComponent("Album/Disc 1/01.mp3")))
  }

  func testAlbumThatFailedEntirelyStaysTogether() throws {
    let album = folder.appendingPathComponent("Album")
    let broken = try write("Album/01.mp3")
    try write("Album/cover.jpg")
    inbox.finish(album, imported: [], failed: [ImportInbox.key(broken)], unfinished: false)
    XCTAssertTrue(exists(inbox.notImported.appendingPathComponent("Album/01.mp3")))
    XCTAssertTrue(exists(inbox.notImported.appendingPathComponent("Album/cover.jpg")))
    XCTAssertFalse(exists(inbox.notImported.appendingPathComponent("Album 2")))
  }

  func testCancelledImportKeepsWhatIsLeft() throws {
    let album = folder.appendingPathComponent("Album")
    let done = try write("Album/01.mp3")
    let left = try write("Album/02.mp3")
    inbox.finish(album, imported: [ImportInbox.key(done)], failed: [], unfinished: true)
    XCTAssertFalse(exists(done))
    XCTAssertTrue(exists(left))
  }

  func testFolderWithoutMusicIsSetAsideNotDeleted() throws {
    let photos = folder.appendingPathComponent("Photos")
    try write("Photos/beach.jpg")
    inbox.finish(photos, imported: [], failed: [], unfinished: false)
    XCTAssertFalse(exists(photos))
    XCTAssertTrue(exists(inbox.notImported.appendingPathComponent("Photos/beach.jpg")))
  }

  func testLooseSongLeavesWithItsLyricsAndNamesDoNotCollide() throws {
    let song = try write("Song.mp3")
    try write("Song.lrc")
    inbox.finish(song, imported: [ImportInbox.key(song)], failed: [], unfinished: false)
    XCTAssertFalse(exists(song))
    XCTAssertFalse(exists(folder.appendingPathComponent("Song.lrc")))

    try write("Not Imported/Bad.mp3")
    let bad = try write("Bad.mp3")
    inbox.finish(bad, imported: [], failed: [ImportInbox.key(bad)], unfinished: false)
    XCTAssertTrue(exists(inbox.notImported.appendingPathComponent("Bad 2.mp3")))
  }

  // MARK: Helpers

  @discardableResult
  private func write(_ path: String) throws -> URL {
    let url = folder.appendingPathComponent(path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("fixture".utf8).write(to: url)
    return url
  }

  private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
}
