import Foundation

/// Where an import's files came from, which decides what happens to them afterwards.
struct ImportSource {
  enum Origin {
    /// Picked in Files or opened in place from another app: left exactly as it is.
    case external
    /// In Cover Flow's own folder: removed once imported, set aside in Not Imported if it couldn't be.
    case inbox(ImportInbox)
    /// A temporary copy in its own folder under `LibraryStore.staging` (dragged in): deleted afterwards.
    case staged
  }
  var url: URL
  var origin: Origin = .external
}

/// Sources waiting for the import that's running, and the caller to wake when they're done.
struct PendingImport {
  let sources: [ImportSource]
  let done: CheckedContinuation<Void, Never>?
}

extension LibraryStore {
  /// Temporary space for dragged-in files and unpacked zip archives; emptied after each import and at launch.
  nonisolated static var staging: URL {
    let url = AppPaths.root.appendingPathComponent("Import Staging", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  nonisolated static func clearStaging() {
    try? FileManager.default.removeItem(at: staging)
  }

  func importURLs(_ urls: [URL]) async {
    await enqueue(urls.map { ImportSource(url: $0) })
  }

  /// Imports sources and returns once they're in the collection. One import runs at a time: sources that
  /// arrive meanwhile (several files AirDropped together, a drop during an import, new files in the folder)
  /// wait their turn instead of being turned away, and the whole run ends with a single report.
  func enqueue(_ sources: [ImportSource]) async {
    guard !sources.isEmpty else { return }
    if importing {
      await withCheckedContinuation { importQueue.append(PendingImport(sources: sources, done: $0)) }
      return
    }
    importing = true
    cancelRequested = false
    importFraction = 0
    var report = MobileImportReport()
    var batch: PendingImport? = PendingImport(sources: sources, done: nil)
    while let current = batch {
      await run(current.sources, report: &report)
      current.done?.resume()
      batch = importQueue.isEmpty ? nil : importQueue.removeFirst()
    }
    lastImportWasCancelled = cancelRequested
    importing = false
    importLabel = ""
    importFraction = 1
    saveNow()
    lastReport = report
  }

  /// One source on its way in: the folder whose audio is imported (an unpacked copy, for a zip archive).
  private struct Work {
    var source: ImportSource
    var root: URL
    var audio: [URL] = []
    var unsupported: [URL] = []
    /// The temporary folder a zip archive was unpacked into.
    var unpacked: URL?
    var archiveFailed = false
  }

  private func run(_ sources: [ImportSource], report: inout MobileImportReport) async {
    // Files picked in the Files app need their access opened for the duration of the import.
    let scoped = sources.compactMap { source -> URL? in
      guard case .external = source.origin, source.url.startAccessingSecurityScopedResource() else {
        return nil
      }
      return source.url
    }
    defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }

    // 1. Unpack zip archives and find the audio in each source.
    var work: [Work] = []
    for source in sources {
      var item = Work(source: source, root: source.url)
      if source.url.pathExtension.lowercased() == "zip" {
        importLabel = source.url.lastPathComponent
        let archive = source.url
        let unpacked = Self.staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let folder = unpacked.appendingPathComponent(
          archive.deletingPathExtension().lastPathComponent, isDirectory: true)
        do {
          try await Task.detached(priority: .userInitiated) {
            try LocalAudioImport.coordinated(archive) { _ = try ZipArchive.extract($0, to: folder) }
          }.value
          item.root = folder
          item.unpacked = unpacked
        } catch {
          try? FileManager.default.removeItem(at: unpacked)
          report.failures.append("\(archive.lastPathComponent): \(error.localizedDescription)")
          item.archiveFailed = true
          work.append(item)
          continue
        }
      }
      let root = item.root
      let found = await Task.detached(priority: .userInitiated) { Self.enumerate([root]) }.value
      item.audio = found.audio
      item.unsupported = found.unsupported
      work.append(item)
    }

    // 2. Import each song.
    var imported = Set<String>()
    var failed = Set<String>()
    for item in work {
      for file in item.unsupported {
        failed.insert(ImportInbox.key(file))
        report.failures.append("\(file.lastPathComponent): unsupported audio format")
      }
    }
    var fingerprints = Set(tracks.values.map(\.fingerprint))
    let total = max(1, work.reduce(0) { $0 + $1.audio.count })
    var done = 0
    songs: for item in work {
      for file in item.audio {
        if cancelRequested || Task.isCancelled { break songs }
        importLabel = file.lastPathComponent
        importFraction = Double(done) / Double(total)
        done += 1
        // Untagged songs are named after their folder, but a song dropped loose into Cover Flow's folder or
        // onto the window has no album folder: its parent is just Inbox or a temporary folder.
        let loose = file.deletingLastPathComponent().standardizedFileURL
          == item.root.deletingLastPathComponent().standardizedFileURL
        var external = false
        if case .external = item.source.origin { external = true }
        let fallback =
          loose && !external ? "Unknown Album" : file.deletingLastPathComponent().lastPathComponent
        switch await importFile(file, albumFallback: fallback, fingerprints: &fingerprints) {
        case .added:
          report.added += 1
          imported.insert(ImportInbox.key(file))
          if report.added % 10 == 0 { saveNow() }
        case .duplicate:
          report.duplicates += 1
          imported.insert(ImportInbox.key(file))
        case .failed(let message):
          report.failures.append("\(file.lastPathComponent): \(message)")
          failed.insert(ImportInbox.key(file))
        }
      }
    }

    // 3. Tidy up: temporary copies go, and Cover Flow's folder keeps only what's still to do.
    for item in work {
      let keys = item.audio.map(ImportInbox.key)
      let unfinished = keys.contains { !imported.contains($0) && !failed.contains($0) }
      let anyFailed = !item.unsupported.isEmpty || keys.contains { failed.contains($0) }
      switch item.source.origin {
      case .external:
        break
      case .staged:
        try? FileManager.default.removeItem(at: item.source.url.deletingLastPathComponent())
      case .inbox(let inbox):
        if item.archiveFailed {
          inbox.setAside(item.source.url)
        } else if item.unpacked != nil {
          // A zip archive leaves once all its songs are in; otherwise it waits in Not Imported. After a
          // Cancel it stays where it is, to be imported next time.
          if !unfinished {
            if anyFailed || item.audio.isEmpty {
              inbox.setAside(item.source.url)
            } else {
              try? FileManager.default.removeItem(at: item.source.url)
            }
          }
        } else {
          inbox.finish(item.source.url, imported: imported, failed: failed, unfinished: unfinished)
        }
      }
      if let unpacked = item.unpacked { try? FileManager.default.removeItem(at: unpacked) }
    }
  }
}
