import Compression
import Foundation

/// Unpacks .zip albums (Bandcamp and similar downloads) so their audio can be imported. Reads stored and
/// deflated entries, including ZIP64 archives over 4 GB, streaming each file to disk rather than into memory.
enum ZipArchive {
  enum Failure: LocalizedError, Equatable {
    case notAZip, encrypted, unsupportedMethod(Int), corrupt
    var errorDescription: String? {
      switch self {
      case .notAZip: return "This isn’t a zip archive Cover Flow can read."
      case .encrypted: return "This zip archive is password-protected."
      case .unsupportedMethod(let method):
        return "This zip archive uses a compression method Cover Flow can’t read (\(method))."
      case .corrupt: return "This zip archive is damaged or incomplete."
      }
    }
  }

  struct Entry: Equatable {
    var path: String
    var method: Int
    var flags: Int
    var compressedSize: UInt64
    var size: UInt64
    var localHeaderOffset: UInt64
    var isDirectory: Bool { path.hasSuffix("/") }
    var isSymlink = false
  }

  /// Extracts every regular file into `folder` and returns their locations. Mac resource forks, hidden files
  /// and symbolic links are skipped, and no entry can write outside `folder`.
  @discardableResult
  static func extract(_ archive: URL, to folder: URL) throws -> [URL] {
    let handle = try FileHandle(forReadingFrom: archive)
    defer { try? handle.close() }
    let entries = try readDirectory(handle)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var written: [URL] = []
    for entry in entries where !entry.isDirectory && !entry.isSymlink {
      guard let relative = safeRelativePath(entry.path) else { continue }
      if entry.flags & 1 != 0 { throw Failure.encrypted }
      guard entry.method == 0 || entry.method == 8 else { throw Failure.unsupportedMethod(entry.method) }
      let destination = folder.appendingPathComponent(relative)
      try FileManager.default.createDirectory(
        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
      try extract(entry, from: handle, to: destination)
      written.append(destination)
    }
    return written
  }

  /// The archive's own path for an entry, made safe: no absolute paths, no "..", no hidden or `__MACOSX`
  /// parts. Nil means the entry should be skipped.
  static func safeRelativePath(_ path: String) -> String? {
    let parts = path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").map(String.init)
      .filter { !$0.isEmpty && $0 != "." }
    guard !parts.isEmpty, !parts.contains(".."), parts.first != "__MACOSX",
      !parts.contains(where: { $0.hasPrefix(".") })
    else { return nil }
    return parts.joined(separator: "/")
  }

  // MARK: Reading the central directory

  static func readDirectory(_ handle: FileHandle) throws -> [Entry] {
    let length = try handle.seekToEnd()
    guard length >= 22 else { throw Failure.notAZip }
    // The end-of-central-directory record sits in the last 22 bytes plus an optional comment (≤ 64 KB).
    let tailLength = min(length, 22 + 65_535)
    let tail = try read(handle, at: length - tailLength, count: Int(tailLength))
    guard let eocd = lastIndex(of: 0x0605_4b50, in: tail, from: tail.count - 22) else {
      throw Failure.notAZip
    }
    var count = UInt64(tail.le16(eocd + 10))
    var directorySize = UInt64(tail.le32(eocd + 12))
    var directoryOffset = UInt64(tail.le32(eocd + 16))
    // ZIP64: a locator 20 bytes before the record points at the 64-bit version.
    if eocd >= 20, tail.le32(eocd - 20) == 0x0706_4b50 {
      let zip64Offset = tail.le64(eocd - 20 + 8)
      let record = try read(handle, at: zip64Offset, count: 56)
      guard record.le32(0) == 0x0606_4b50 else { throw Failure.corrupt }
      count = record.le64(32)
      directorySize = record.le64(40)
      directoryOffset = record.le64(48)
    }
    guard directoryOffset + directorySize <= length, directorySize < 1 << 31 else {
      throw Failure.corrupt
    }
    let directory = try read(handle, at: directoryOffset, count: Int(directorySize))
    var entries: [Entry] = []
    var cursor = 0
    for _ in 0..<count {
      guard cursor + 46 <= directory.count, directory.le32(cursor) == 0x0201_4b50 else {
        throw Failure.corrupt
      }
      let madeBy = directory.le16(cursor + 4)
      let flags = Int(directory.le16(cursor + 8))
      let method = Int(directory.le16(cursor + 10))
      var compressed = UInt64(directory.le32(cursor + 20))
      var size = UInt64(directory.le32(cursor + 24))
      let nameLength = Int(directory.le16(cursor + 28))
      let extraLength = Int(directory.le16(cursor + 30))
      let commentLength = Int(directory.le16(cursor + 32))
      let attributes = directory.le32(cursor + 38)
      var offset = UInt64(directory.le32(cursor + 42))
      let nameStart = cursor + 46
      let extraStart = nameStart + nameLength
      let next = extraStart + extraLength + commentLength
      guard next <= directory.count else { throw Failure.corrupt }
      let nameBytes = directory.subdata(in: nameStart..<extraStart)
      // Bit 11 marks UTF-8 names; older archives use the DOS code page, close enough to Latin-1 for names.
      let name =
        (flags & 0x800 != 0 ? String(data: nameBytes, encoding: .utf8) : nil)
        ?? String(data: nameBytes, encoding: .utf8) ?? String(data: nameBytes, encoding: .isoLatin1) ?? ""
      // ZIP64 extra field: 64-bit values for whichever of the fields above are 0xFFFFFFFF, in this order.
      var extra = extraStart
      while extra + 4 <= extraStart + extraLength {
        let id = directory.le16(extra)
        let fieldLength = Int(directory.le16(extra + 2))
        if id == 0x0001 {
          var field = extra + 4
          func take() -> UInt64? {
            guard field + 8 <= extra + 4 + fieldLength else { return nil }
            defer { field += 8 }
            return directory.le64(field)
          }
          if size == 0xFFFF_FFFF { size = take() ?? size }
          if compressed == 0xFFFF_FFFF { compressed = take() ?? compressed }
          if offset == 0xFFFF_FFFF { offset = take() ?? offset }
        }
        extra += 4 + fieldLength
      }
      // Unix-made archives keep the file mode in the high 16 bits; 0o120000 is a symbolic link.
      let isSymlink = (madeBy >> 8) == 3 && (attributes >> 16) & 0o170000 == 0o120000
      entries.append(
        Entry(
          path: name, method: method, flags: flags, compressedSize: compressed, size: size,
          localHeaderOffset: offset, isSymlink: isSymlink))
      cursor = next
    }
    return entries
  }

  // MARK: Extracting one entry

  private static func extract(_ entry: Entry, from handle: FileHandle, to destination: URL) throws {
    let header = try read(handle, at: entry.localHeaderOffset, count: 30)
    guard header.le32(0) == 0x0403_4b50 else { throw Failure.corrupt }
    let dataStart =
      entry.localHeaderOffset + 30 + UInt64(header.le16(26)) + UInt64(header.le16(28))
    try handle.seek(toOffset: dataStart)
    FileManager.default.createFile(atPath: destination.path, contents: nil)
    let output = try FileHandle(forWritingTo: destination)
    defer { try? output.close() }
    var remaining = entry.compressedSize
    var produced: UInt64 = 0
    let chunk = 1 << 20
    if entry.method == 0 {
      while remaining > 0 {
        guard let data = try handle.read(upToCount: Int(min(UInt64(chunk), remaining))), !data.isEmpty
        else { throw Failure.corrupt }
        try output.write(contentsOf: data)
        remaining -= UInt64(data.count)
        produced += UInt64(data.count)
      }
    } else {
      // Compression's "zlib" is raw DEFLATE (RFC 1951), which is what zip archives contain.
      var overflow = false
      let filter = try OutputFilter(.decompress, using: .zlib) { data in
        guard let data else { return }
        produced += UInt64(data.count)
        // A file bigger than the archive says is damaged, or a zip bomb: stop writing.
        if produced > entry.size { overflow = true; return }
        try output.write(contentsOf: data)
      }
      while remaining > 0 {
        guard let data = try handle.read(upToCount: Int(min(UInt64(chunk), remaining))), !data.isEmpty
        else { throw Failure.corrupt }
        remaining -= UInt64(data.count)
        do { try filter.write(data) } catch { throw Failure.corrupt }
        if overflow { throw Failure.corrupt }
      }
      do { try filter.finalize() } catch { throw Failure.corrupt }
      if overflow { throw Failure.corrupt }
    }
    guard produced == entry.size else { throw Failure.corrupt }
  }

  // MARK: Bytes

  private static func read(_ handle: FileHandle, at offset: UInt64, count: Int) throws -> Data {
    try handle.seek(toOffset: offset)
    guard let data = try handle.read(upToCount: count), data.count == count else {
      throw Failure.corrupt
    }
    return data
  }

  private static func lastIndex(of signature: UInt32, in data: Data, from start: Int) -> Int? {
    var index = start
    while index >= 0 {
      if data.le32(index) == signature { return index }
      index -= 1
    }
    return nil
  }
}

extension Data {
  fileprivate func le16(_ offset: Int) -> UInt16 {
    let base = startIndex + offset
    return UInt16(self[base]) | UInt16(self[base + 1]) << 8
  }
  fileprivate func le32(_ offset: Int) -> UInt32 {
    UInt32(le16(offset)) | UInt32(le16(offset + 2)) << 16
  }
  fileprivate func le64(_ offset: Int) -> UInt64 {
    UInt64(le32(offset)) | UInt64(le32(offset + 4)) << 32
  }
}
