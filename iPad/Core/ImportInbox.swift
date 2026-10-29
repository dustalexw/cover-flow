import Foundation

/// Cover Flow's own folder (Files › On My iPad › Cover Flow, or the iPad's Files tab in Finder) works as a drop
/// box: anything put there is added to the collection. Once a song is in the collection (which keeps its own
/// copy) it leaves the folder; anything that couldn't be added moves to "Not Imported" so it's easy to find.
/// AirDrop and "Open in" copies that iOS places in the folder's Inbox are handled the same way.
struct ImportInbox {
  static let notImportedName = "Not Imported"
  let folder: URL
  var notImported: URL { folder.appendingPathComponent(Self.notImportedName, isDirectory: true) }

  /// Items finished copying and ready to import, and whether others are still being copied in (check again
  /// shortly). An item counts as finished once nothing in it has changed for `settle` seconds.
  func readyItems(now: Date = Date(), settle: TimeInterval = 4) -> (ready: [URL], stillCopying: Bool) {
    let fm = FileManager.default
    var candidates: [URL] = []
    // iOS finishes copying AirDrop and "Open in" files into Inbox before it opens the app.
    var delivered = Set<URL>()
    let top = (try? fm.contentsOfDirectory(
      at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
    for item in top {
      switch item.lastPathComponent {
      case Self.notImportedName: continue
      case "Inbox":
        let inbox = (try? fm.contentsOfDirectory(
          at: item, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        candidates += inbox
        delivered.formUnion(inbox)
      default: candidates.append(item)
      }
    }
    candidates = candidates.filter { !Self.isSidecarOfAnotherItem($0, among: candidates) }
    var ready: [URL] = []
    var stillCopying = false
    for item in candidates {
      if !delivered.contains(item) && now.timeIntervalSince(Self.lastChange(item)) < settle {
        stillCopying = true
      } else {
        ready.append(item)
      }
    }
    return (ready.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }, stillCopying)
  }

  /// Tidies an item after an import: songs now in the collection are removed (with their .lrc lyrics), and
  /// songs that couldn't be added move to Not Imported. Once nothing in the item is left to try, a folder
  /// whose music was added is removed with its leftovers (covers, playlists…); a folder with no music in it
  /// is set aside in Not Imported instead, so nothing the user didn't mean to import is deleted.
  /// `imported` and `failed` hold `key(_:)` paths.
  func finish(_ item: URL, imported: Set<String>, failed: Set<String>, unfinished: Bool) {
    let fm = FileManager.default
    let isFolder = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    let files: [URL] =
      isFolder
      ? (fm.enumerator(at: item, includingPropertiesForKeys: [.isRegularFileKey], options: [])?
        .compactMap { $0 as? URL } ?? [])
      : [item]
    var addedAny = false
    let itemPath = Self.key(item)
    for file in files {
      let path = Self.key(file)
      if imported.contains(path) {
        addedAny = true
        Self.removeWithLyrics(file)
      } else if failed.contains(path) {
        let relative =
          isFolder
          ? item.lastPathComponent + "/" + String(path.dropFirst(itemPath.count + 1))
          : file.lastPathComponent
        setAside(file, as: relative, withLyrics: true)
      }
    }
    guard isFolder, !unfinished, fm.fileExists(atPath: item.path) else { return }
    if addedAny || Self.isEmpty(item) {
      try? fm.removeItem(at: item)
    } else {
      setAside(item, as: item.lastPathComponent, withLyrics: false)
    }
  }

  /// Moves something into Not Imported, keeping its name (numbered if that name is taken).
  func setAside(_ item: URL, as relativePath: String? = nil, withLyrics: Bool = false) {
    let fm = FileManager.default
    var destination = notImported.appendingPathComponent(relativePath ?? item.lastPathComponent)
    try? fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    destination = Self.unusedName(destination)
    let lyrics = withLyrics ? Self.lyrics(for: item) : nil
    guard (try? fm.moveItem(at: item, to: destination)) != nil else { return }
    if let lyrics {
      try? fm.moveItem(
        at: lyrics, to: Self.unusedName(destination.deletingPathExtension().appendingPathExtension("lrc")))
    }
  }

  // MARK: Helpers

  /// How imported and failed files are identified: iOS can name the same file through /var or /private/var.
  static func key(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }

  /// The most recent change anywhere in an item: while Finder or Files is still copying, this keeps moving.
  static func lastChange(_ item: URL) -> Date {
    let keys: Set<URLResourceKey> = [.contentModificationDateKey, .creationDateKey]
    func changed(_ url: URL) -> Date {
      let values = try? url.resourceValues(forKeys: keys)
      return max(values?.contentModificationDate ?? .distantPast, values?.creationDate ?? .distantPast)
    }
    var latest = changed(item)
    if let walker = FileManager.default.enumerator(at: item, includingPropertiesForKeys: Array(keys)) {
      for case let url as URL in walker { latest = max(latest, changed(url)) }
    }
    return latest
  }

  /// "Song.lrc" next to "Song.mp3" is imported with the song, not as an item of its own.
  static func isSidecarOfAnotherItem(_ item: URL, among items: [URL]) -> Bool {
    guard item.pathExtension.lowercased() == "lrc" else { return false }
    let base = item.deletingPathExtension().lastPathComponent.lowercased()
    return items.contains {
      $0 != item && $0.pathExtension.lowercased() != "lrc"
        && $0.deletingPathExtension().lastPathComponent.lowercased() == base
        && $0.deletingLastPathComponent().standardizedFileURL == item.deletingLastPathComponent().standardizedFileURL
    }
  }

  static func lyrics(for audio: URL) -> URL? {
    let wanted = audio.deletingPathExtension().appendingPathExtension("lrc").lastPathComponent
    let siblings = (try? FileManager.default.contentsOfDirectory(
      at: audio.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
    return siblings.first { $0.lastPathComponent.caseInsensitiveCompare(wanted) == .orderedSame }
  }

  static func removeWithLyrics(_ audio: URL) {
    if let lyrics = lyrics(for: audio) { try? FileManager.default.removeItem(at: lyrics) }
    try? FileManager.default.removeItem(at: audio)
  }

  static func isEmpty(_ folder: URL) -> Bool {
    guard let walker = FileManager.default.enumerator(
      at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
    else { return true }
    for case let url as URL in walker
    where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
      return false
    }
    return true
  }

  static func unusedName(_ url: URL) -> URL {
    guard FileManager.default.fileExists(atPath: url.path) else { return url }
    let base = url.deletingPathExtension().lastPathComponent
    let ext = url.pathExtension
    for number in 2... {
      let name = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
      let candidate = url.deletingLastPathComponent().appendingPathComponent(name)
      if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
    }
    return url
  }
}
