import Foundation
import UniformTypeIdentifiers

/// Brings music in without the Import button:
/// - files put in Cover Flow's folder from Finder (the iPad's Files tab) or the Files app,
/// - AirDrop and "Open in" copies, which iOS places in that folder's Inbox,
/// - files, folders and zip archives dragged onto the window.
@MainActor final class MobileImportInbox {
  let inbox = ImportInbox(
    folder: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0])
  private let library: LibraryStore
  private var watcher: DispatchSourceFileSystemObject?
  private var pendingScan: Task<Void, Never>?
  /// Folder items already queued, so a second look at the folder doesn't queue them again.
  private var inFlight = Set<String>()
  /// After Cancel, the folder isn't imported again until something new arrives in it.
  private var paused = false
  /// Tidying the folder after an import changes it too; that mustn't count as something new arriving.
  private var quietUntil = Date.distantPast

  init(library: LibraryStore) {
    self.library = library
  }

  func start() {
    LibraryStore.clearStaging()
    let descriptor = Darwin.open(inbox.folder.path, O_EVTONLY)
    if descriptor >= 0 {
      let source = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: descriptor, eventMask: [.write, .rename], queue: .main)
      source.setEventHandler { [weak self] in
        MainActor.assumeIsolated { self?.folderChanged() }
      }
      source.setCancelHandler { close(descriptor) }
      source.resume()
      watcher = source
    }
    scan(after: 0.5)
  }

  /// The app came back to the foreground: files may have arrived while it was suspended.
  func appBecameActive() { scan(after: 0.5) }

  /// A file opened with Cover Flow (AirDrop, "Open in", the Files app).
  func open(_ url: URL) {
    if ImportInbox.key(url).hasPrefix(ImportInbox.key(inbox.folder) + "/") {
      // A copy iOS put in the folder's Inbox: the folder import picks it up with anything else that arrived.
      paused = false
      scan(after: 0.3)
    } else {
      // Opened in place from another app's storage: imported, and the original left alone.
      Task { await library.importURLs([url]) }
    }
  }

  // MARK: The folder

  private func folderChanged() {
    if Date() > quietUntil { paused = false }
    scan(after: 1)
  }

  private func scan(after delay: TimeInterval) {
    pendingScan?.cancel()
    pendingScan = Task { [weak self] in
      try? await Task.sleep(for: .seconds(delay))
      guard !Task.isCancelled else { return }
      // The import runs in a task of its own, so a later scan(after:) can't cancel it halfway.
      Task { await self?.scanNow() }
    }
  }

  private func scanNow() async {
    guard !paused else { return }
    let (ready, stillCopying) = inbox.readyItems()
    if stillCopying { scan(after: 2) }
    let fresh = ready.filter { !inFlight.contains(ImportInbox.key($0)) }
    guard !fresh.isEmpty else { return }
    let keys = fresh.map(ImportInbox.key)
    inFlight.formUnion(keys)
    await library.enqueue(fresh.map { ImportSource(url: $0, origin: .inbox(inbox)) })
    inFlight.subtract(keys)
    quietUntil = Date().addingTimeInterval(2)
    if library.lastImportWasCancelled { paused = true }
  }

  // MARK: Drag and drop

  /// Accepts dropped audio files, folders and zip archives. Returns false if none of the items is a file.
  func accept(_ providers: [NSItemProvider]) -> Bool {
    var accepted = false
    for provider in providers {
      guard let type = Self.fileType(of: provider) else { continue }
      accepted = true
      let folder = LibraryStore.staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
      _ = provider.loadFileRepresentation(forTypeIdentifier: type) { [weak self] url, error in
        // iOS deletes this copy as soon as the handler returns, so keep one of our own first.
        var copy: URL?
        var problem = error?.localizedDescription
        if let url {
          let destination = folder.appendingPathComponent(url.lastPathComponent)
          do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: destination)
            copy = destination
          } catch {
            problem = error.localizedDescription
          }
        }
        Task { @MainActor in
          guard let self else { return }
          if let copy {
            await self.library.enqueue([ImportSource(url: copy, origin: .staged)])
          } else {
            self.library.notice = "Couldn’t add the dropped item. \(problem ?? "")"
          }
        }
      }
    }
    return accepted
  }

  /// The type to ask a dropped item for: audio, a folder, a zip archive or another file — not text, links
  /// or pictures, which aren't music.
  static func fileType(of provider: NSItemProvider) -> String? {
    let types = provider.registeredTypeIdentifiers.compactMap(UTType.init)
    let preferred: [UTType] = [.folder, .zip, .audio, .movie]
    for wanted in preferred {
      if let match = types.first(where: { $0.conforms(to: wanted) }) { return match.identifier }
    }
    return types.first {
      $0.conforms(to: .data) && !$0.conforms(to: .image) && !$0.conforms(to: .text)
        && !$0.conforms(to: .url)
    }?.identifier
  }
}
