import CryptoKit
import Foundation

enum LocalAudioImport {
  static func enumerate(_ urls: [URL], supported: Set<String>, knownUnsupported: Set<String>) -> (
    audio: [URL], unsupported: [URL]
  ) {
    var audio: [URL] = []
    var unsupported: [URL] = []
    var seen = Set<String>()
    func consider(_ url: URL, explicit: Bool) {
      guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
        seen.insert(url.standardizedFileURL.path).inserted
      else { return }
      let ext = url.pathExtension.lowercased()
      if supported.contains(ext) {
        audio.append(url)
      } else if explicit || knownUnsupported.contains(ext) {
        unsupported.append(url)
      }
    }
    for url in urls {
      if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
        if let files = FileManager.default.enumerator(
          at: url, includingPropertiesForKeys: [.isRegularFileKey],
          options: [.skipsHiddenFiles, .skipsPackageDescendants])
        {
          for case let file as URL in files { consider(file, explicit: false) }
        }
      } else {
        consider(url, explicit: true)
      }
    }
    return (
      audio.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }, unsupported
    )
  }
  static func coordinated<T>(_ url: URL, read: (URL) throws -> T) throws -> T {
    #if os(macOS)
      // The portable verification library reads owned local fixtures on macOS.
      // iPad file-provider coordination is handled by the branch below.
      return try read(url)
    #else
      let coordinator = NSFileCoordinator()
      var error: NSError?
      var result: Result<T, Error>?
      coordinator.coordinate(readingItemAt: url, options: [], error: &error) { location in
        result = Result { try read(location) }
      }
      if let error { throw error }
      guard let result else { throw CocoaError(.fileReadUnknown) }
      return try result.get()
    #endif
  }
  static func digest(_ url: URL) throws -> String {
    try coordinated(url) { url in
      let file = try FileHandle(forReadingFrom: url)
      defer { try? file.close() }
      var hash = SHA256()
      while let data = try file.read(upToCount: 1_048_576), !data.isEmpty {
        hash.update(data: data)
      }
      return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
  }
  static func copyAudio(_ source: URL, to folder: URL) throws -> URL {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let destination = folder.appendingPathComponent(source.lastPathComponent)
    try coordinated(source) { try FileManager.default.copyItem(at: $0, to: destination) }
    #if os(iOS)
      try FileManager.default.setAttributes(
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
        ofItemAtPath: destination.path)
    #endif
    let sidecar = source.deletingPathExtension().appendingPathExtension("lrc")
    let siblings =
      (try? FileManager.default.contentsOfDirectory(
        at: source.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
    if let lyrics = siblings.first(where: {
      $0.lastPathComponent.caseInsensitiveCompare(sidecar.lastPathComponent) == .orderedSame
    }) {
      try? coordinated(lyrics) {
        try FileManager.default.copyItem(
          at: $0, to: destination.deletingPathExtension().appendingPathExtension("lrc"))
      }
    }
    return destination
  }
  static func mediaURL(root: URL, id: UUID, filename: String) -> URL {
    root.appendingPathComponent(id.uuidString).appendingPathComponent(
      (filename as NSString).lastPathComponent)
  }
}
