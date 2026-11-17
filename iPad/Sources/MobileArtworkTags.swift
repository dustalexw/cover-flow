import Foundation
import SwiftUI

enum ArtworkError: LocalizedError {
  case notAnImage
  var errorDescription: String? { "That file isn’t an image Cover Flow can read." }
}

/// Embeds replaced covers in the album's imported audio files, as the Mac app does,
/// when the project is built with TagLib (`scripts/build-ios-native.sh`). Without it,
/// covers are saved to the collection only. Only the app's own imported copies are
/// rewritten; files in Files, iCloud Drive or on attached drives are never touched.
@MainActor final class MobileArtworkTagging: ObservableObject {
  private let library: LibraryStore
  @Published private(set) var writing = false
  init(library: LibraryStore) { self.library = library }

  static var available: Bool {
    #if canImport(CArtworkTags)
      return true
    #else
      return false
    #endif
  }
  var saveDescription: String {
    Self.available
      ? "The cover will be saved to this device’s collection and embedded in the album’s imported audio files."
      : "The cover will be saved to this device’s collection."
  }

  func embed(_ data: Data, album id: UUID) {
    #if canImport(CArtworkTags)
      guard let album = library.album(id), !album.isDemo else { return }
      let owned = AppPaths.root.standardizedFileURL.path
      let urls = library.tracks(of: album).map(\.fileURL).filter {
        $0.standardizedFileURL.path.hasPrefix(owned)
          && ArtworkTagWriter.supportedExtensions.contains($0.pathExtension.lowercased())
      }
      guard !urls.isEmpty else { return }
      writing = true
      Task { [weak self] in
        let message: String?
        do {
          let artwork = try await Task.detached(priority: .userInitiated) {
            try EmbeddedArtwork.prepare(data)
          }.value
          let report = await ArtworkTagWriter.shared.embed(artwork, in: urls)
          message =
            report.failures.isEmpty
            ? nil : report.summary + "\n\n" + report.failures.prefix(8).joined(separator: "\n")
        } catch {
          message = error.localizedDescription
        }
        guard let self else { return }
        self.writing = false
        if let message { self.library.notice = message }
      }
    #endif
  }
}
