import XCTest

@testable import iPadSignal

final class ZipArchiveTests: XCTestCase {
  private var root: URL!

  override func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: root)
  }

  /// An album zipped the way Finder and Bandcamp do it: deflated, in a folder, with a Mac resource fork.
  func testExtractsDeflatedAlbumWithUnicodeNamesAndSkipsMacExtras() throws {
    let album = root.appendingPathComponent("source/Café Album")
    try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
    let song = Data((0..<200_000).map { UInt8($0 % 7) })  // compresses well
    try song.write(to: album.appendingPathComponent("01 Señorita.flac"))
    try Data("[00:01]Hi".utf8).write(to: album.appendingPathComponent("01 Señorita.lrc"))
    try Data("hidden".utf8).write(to: album.appendingPathComponent(".DS_Store"))
    let archive = root.appendingPathComponent("album.zip")
    try zip(root.appendingPathComponent("source"), to: archive, arguments: ["-r", "-X"])

    let out = root.appendingPathComponent("out")
    let files = try ZipArchive.extract(archive, to: out)
    XCTAssertEqual(
      Set(files.map(\.lastPathComponent)), ["01 Señorita.flac", "01 Señorita.lrc"])
    XCTAssertEqual(
      try Data(contentsOf: out.appendingPathComponent("Café Album/01 Señorita.flac")), song)
  }

  func testExtractsStoredAndZip64Archives() throws {
    let source = root.appendingPathComponent("source")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let song = Data((0..<50_000).map { _ in UInt8.random(in: 0...255) })
    try song.write(to: source.appendingPathComponent("track.mp3"))
    for (name, options) in [("stored.zip", ["-0"]), ("zip64.zip", ["-fz"])] {
      let archive = root.appendingPathComponent(name)
      try zip(source, to: archive, arguments: ["-r", "-X"] + options)
      let out = root.appendingPathComponent("out-" + name)
      try ZipArchive.extract(archive, to: out)
      XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent("track.mp3")), song, name)
    }
  }

  func testEntriesCannotEscapeTheDestination() throws {
    let archive = root.appendingPathComponent("evil.zip")
    try Self.storedZip([
      ("../escaped.mp3", Data("x".utf8)), ("/absolute.mp3", Data("y".utf8)),
      ("__MACOSX/._song.mp3", Data("z".utf8)), ("Album/song.mp3", Data("ok".utf8)),
    ]).write(to: archive)
    let out = root.appendingPathComponent("out")
    let files = try ZipArchive.extract(archive, to: out)
    XCTAssertEqual(files.map { $0.path.replacingOccurrences(of: out.path + "/", with: "") },
                   ["absolute.mp3", "Album/song.mp3"])
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("escaped.mp3").path))
    XCTAssertNil(ZipArchive.safeRelativePath("a/../../b"))
    XCTAssertEqual(ZipArchive.safeRelativePath("a\\b.mp3"), "a/b.mp3")
  }

  func testRejectsFilesThatAreNotZipsOrAreDamaged() throws {
    let text = root.appendingPathComponent("notes.zip")
    try Data("not a zip at all, just some text".utf8).write(to: text)
    XCTAssertThrowsError(try ZipArchive.extract(text, to: root.appendingPathComponent("a"))) {
      XCTAssertEqual($0 as? ZipArchive.Failure, .notAZip)
    }
    var bytes = try Self.storedZip([("song.mp3", Data(repeating: 1, count: 1000))])
    bytes.replaceSubrange(30..<40, with: Data(repeating: 0, count: 10))  // break the local header name
    bytes[0] = 0
    let damaged = root.appendingPathComponent("damaged.zip")
    try bytes.write(to: damaged)
    XCTAssertThrowsError(try ZipArchive.extract(damaged, to: root.appendingPathComponent("b")))
  }

  // MARK: Helpers

  private func zip(_ folder: URL, to archive: URL, arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    process.currentDirectoryURL = folder
    process.arguments = ["-q"] + arguments + [archive.path, "."]
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
  }

  /// A minimal stored (uncompressed) zip with exactly these entry names, including ones `zip` won't write.
  static func storedZip(_ entries: [(String, Data)]) throws -> Data {
    var body = Data()
    var directory = Data()
    func le16(_ value: Int) -> Data { withUnsafeBytes(of: UInt16(value).littleEndian) { Data($0) } }
    func le32(_ value: Int) -> Data { withUnsafeBytes(of: UInt32(value).littleEndian) { Data($0) } }
    for (name, data) in entries {
      let nameBytes = Data(name.utf8)
      let offset = body.count
      body += le32(0x0403_4b50) + le16(20) + le16(0x800) + le16(0) + le16(0) + le16(0) + le32(0)
        + le32(data.count) + le32(data.count) + le16(nameBytes.count) + le16(0) + nameBytes + data
      directory += le32(0x0201_4b50) + le16(20) + le16(20) + le16(0x800) + le16(0) + le16(0) + le16(0)
        + le32(0) + le32(data.count) + le32(data.count) + le16(nameBytes.count) + le16(0) + le16(0)
        + le16(0) + le16(0) + le32(0) + le32(offset) + nameBytes
    }
    let end = le32(0x0605_4b50) + le16(0) + le16(0) + le16(entries.count) + le16(entries.count)
      + le32(directory.count) + le32(body.count) + le16(0)
    return body + directory + end
  }
}
