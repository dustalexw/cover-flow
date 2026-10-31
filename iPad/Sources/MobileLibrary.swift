import Combine
import CryptoKit
import Foundation
import ImageIO
import UIKit

struct MobileImportReport: Identifiable {
  let id = UUID()
  var added = 0, duplicates = 0
  var failures: [String] = []
  var summary: String { "Imported \(added) track(s). \(duplicates) duplicate(s)." }
}
struct MobileLibraryFile: Codable {
  var albums: [Album]
  var tracks: [Track]
}

/// iPad owns its imported copies. UUID media directories are resolved again after
/// container moves/restores instead of trusting persisted absolute sandbox paths.
@MainActor final class LibraryStore: ObservableObject {
  @Published private(set) var albums: [Album] = []
  @Published private(set) var tracks: [UUID: Track] = [:]
  @Published private(set) var importing = false
  @Published private(set) var importFraction = 0.0
  @Published private(set) var importLabel = ""
  @Published var lastReport: MobileImportReport?
  @Published var notice: String?
  let artwork = ArtworkStore()
  var onTracksRemoved: ((Set<UUID>) -> Void)?
  var onMetadataChanged: (() -> Void)?
  private var cancelImport = false
  static var media: URL {
    let url = AppPaths.root.appendingPathComponent("Media", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
  func album(_ id: UUID?) -> Album? { albums.first { $0.id == id } }
  func track(_ id: UUID?) -> Track? { id.flatMap { tracks[$0] } }
  func albumID(forTrack id: UUID) -> UUID? { albums.first { $0.trackIDs.contains(id) }?.id }
  func tracks(of album: Album) -> [Track] { album.trackIDs.compactMap { tracks[$0] } }
  func totalDuration(_ album: Album) -> Double { tracks(of: album).reduce(0) { $0 + $1.duration } }
  func visibleAlbums(sort: SortOrder, search: String) -> [Album] {
    let query = search.normalizedKey
    var result = albums.filter { album in
      query.isEmpty
        || ([album.title, album.artist, album.genre ?? ""]
          + tracks(of: album).flatMap { [$0.title, $0.artist] })
          .contains { $0.normalizedKey.contains(query) }
    }
    result.sort { a, b in
      switch sort {
      case .artist:
        return (a.artist.normalizedKey, a.year ?? 9999, a.title.normalizedKey) < (
          b.artist.normalizedKey, b.year ?? 9999, b.title.normalizedKey
        )
      case .title: return a.title.localizedStandardCompare(b.title) == .orderedAscending
      case .recentlyAdded: return a.dateAdded > b.dateAdded
      case .recentlyPlayed: return (a.lastPlayed ?? .distantPast) > (b.lastPlayed ?? .distantPast)
      }
    }
    return result
  }
  func load() {
    guard FileManager.default.fileExists(atPath: AppPaths.library.path) else { return }
    do {
      let saved = try JSONDecoder().decode(
        MobileLibraryFile.self, from: Data(contentsOf: AppPaths.library))
      var restored: [UUID: Track] = [:]
      for var track in saved.tracks {
        track.fileURL = LocalAudioImport.mediaURL(
          root: Self.media, id: track.id, filename: track.fileURL.lastPathComponent)
        restored[track.id] = track
      }
      tracks = restored
      albums = saved.albums
    } catch {
      notice =
        "The saved collection could not be opened. Its files are still on this device. \(error.localizedDescription)"
    }
  }
  func saveNow() {
    do {
      try JSONEncoder().encode(MobileLibraryFile(albums: albums, tracks: Array(tracks.values)))
        .write(to: AppPaths.library, options: .atomic)
    } catch { notice = "Couldn’t save your library: \(error.localizedDescription)" }
  }
  func markPlayed(trackID: UUID) {
    guard let index = albums.firstIndex(where: { $0.trackIDs.contains(trackID) }) else { return }
    albums[index].lastPlayed = Date()
    saveNow()
  }
  func cancel() { cancelImport = true }
  func importURLs(_ urls: [URL]) async {
    guard !importing else { return }
    importing = true
    cancelImport = false
    importFraction = 0
    defer {
      importing = false
      importLabel = ""
      saveNow()
    }
    var report = MobileImportReport()
    var fingerprints = Set(tracks.values.map(\.fingerprint))
    let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
    defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
    let discovered = await Task.detached(priority: .userInitiated) { Self.enumerate(urls) }.value
    report.failures = discovered.unsupported.map {
      "\($0.lastPathComponent): unsupported audio format"
    }
    for (index, source) in discovered.audio.enumerated() {
      if cancelImport || Task.isCancelled { break }
      importLabel = source.lastPathComponent
      importFraction = Double(index) / Double(max(1, discovered.audio.count))
      let id = UUID()
      let folder = Self.media.appendingPathComponent(id.uuidString, isDirectory: true)
      do {
        let fingerprint = try await Task.detached(priority: .userInitiated) {
          try Self.digest(source)
        }.value
        if fingerprints.contains(fingerprint) {
          report.duplicates += 1
          continue
        }
        // Coordinate provider downloads/copies first; metadata reads the owned file.
        let destination = try await Task.detached(priority: .userInitiated) {
          try Self.copyAudio(source, to: folder)
        }.value
        let meta = try await MetadataReader.read(destination)
        let title = meta.title?.nonEmpty ?? source.deletingPathExtension().lastPathComponent
        let artist = meta.artist?.nonEmpty ?? "Unknown Artist"
        let albumTitle =
          meta.album?.nonEmpty ?? source.deletingLastPathComponent().lastPathComponent
        let missing = meta.usedFallback || meta.artist?.nonEmpty == nil
        let groupArtist = meta.albumArtist?.nonEmpty ?? artist
        let key = albumTitle.normalizedKey + "\n" + groupArtist.normalizedKey
        let track = Track(
          id: id, fileURL: destination, title: title, artist: artist, albumTitle: albumTitle,
          albumArtist: meta.albumArtist, trackNumber: meta.trackNumber, discNumber: meta.discNumber,
          duration: meta.duration, year: meta.year, genre: meta.genre, dateAdded: Date(),
          isDemo: false, missingMetadata: missing, fingerprint: fingerprint)
        tracks[id] = track
        fingerprints.insert(fingerprint)
        let albumIndex: Int
        if let index = albums.firstIndex(where: { $0.groupKey == key }) {
          albumIndex = index
          albums[index].trackIDs.append(id)
        } else {
          albums.append(
            Album(
              id: UUID(), groupKey: key, title: albumTitle, artist: groupArtist, year: meta.year,
              genre: meta.genre, trackIDs: [id], artworkFile: nil, artworkPixelWidth: nil,
              artworkPixelHeight: nil, artworkVersion: 0, tintHex: nil, dateAdded: Date(),
              lastPlayed: nil, isDemo: false, missingMetadata: missing, userEdited: false)
          )
          albumIndex = albums.count - 1
        }
        albums[albumIndex].trackIDs.sort {
          (tracks[$0]?.sortKey ?? (1, Int.max, "")) < (tracks[$1]?.sortKey ?? (1, Int.max, ""))
        }
        if albums[albumIndex].artworkFile == nil {
          let art = meta.artwork ?? MetadataReader.folderArtwork(near: source)
          if let art { try? setArtwork(albums[albumIndex].id, data: art) }
        }
        report.added += 1
        if report.added % 10 == 0 { saveNow() }
      } catch {
        try? FileManager.default.removeItem(at: folder)
        report.failures.append("\(source.lastPathComponent): \(error.localizedDescription)")
      }
    }
    importFraction = 1
    lastReport = report
  }
  nonisolated static func enumerate(_ urls: [URL]) -> (audio: [URL], unsupported: [URL]) {
    LocalAudioImport.enumerate(
      urls, supported: MetadataReader.supportedExtensions,
      knownUnsupported: MetadataReader.knownUnsupported)
  }
  nonisolated static func coordinated<T>(_ url: URL, read: (URL) throws -> T) throws -> T {
    try LocalAudioImport.coordinated(url, read: read)
  }
  nonisolated static func digest(_ url: URL) throws -> String { try LocalAudioImport.digest(url) }
  nonisolated static func copyAudio(_ source: URL, to folder: URL) throws -> URL {
    try LocalAudioImport.copyAudio(source, to: folder)
  }
  func flagDemo(_ ids: Set<UUID>) {
    for id in ids {
      tracks[id]?.isDemo = true
      tracks[id]?.artist = "Cover Flow Demos"
      tracks[id]?.missingMetadata = false
    }
    for index in albums.indices where !Set(albums[index].trackIDs).isDisjoint(with: ids) {
      albums[index].isDemo = true
      albums[index].artist = "Cover Flow Demos"
      albums[index].missingMetadata = false
    }
    saveNow()
  }
  func updateAlbum(_ id: UUID, title: String, artist: String, year: String, genre: String) {
    guard let index = albums.firstIndex(where: { $0.id == id }) else { return }
    albums[index].title = title.nonEmpty ?? albums[index].title
    albums[index].artist = artist.nonEmpty ?? albums[index].artist
    albums[index].year = Int(year)
    albums[index].genre = genre.nonEmpty
    albums[index].userEdited = true
    for trackID in albums[index].trackIDs {
      tracks[trackID]?.albumTitle = albums[index].title
      tracks[trackID]?.albumArtist = albums[index].artist
    }
    saveNow()
    onMetadataChanged?()
  }
  func updateTrack(_ id: UUID, title: String, artist: String, number: Int?) {
    guard tracks[id] != nil else { return }
    tracks[id]?.title = title.nonEmpty ?? tracks[id]!.title
    tracks[id]?.artist = artist.nonEmpty ?? tracks[id]!.artist
    tracks[id]?.trackNumber = number.flatMap { $0 > 0 ? $0 : nil }
    if let index = albums.firstIndex(where: { $0.trackIDs.contains(id) }) {
      albums[index].trackIDs.sort {
        (tracks[$0]?.sortKey ?? (1, Int.max, "")) < (tracks[$1]?.sortKey ?? (1, Int.max, ""))
      }
    }
    saveNow()
    onMetadataChanged?()
  }
  func updateAppearance(_ id: UUID, appearance: AlbumAppearance) {
    guard let index = albums.firstIndex(where: { $0.id == id }) else { return }
    albums[index].appearance = appearance
    saveNow()
  }
  func setArtwork(_ id: UUID, data: Data) throws {
    guard let index = albums.firstIndex(where: { $0.id == id }),
      let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceThumbnailMaxPixelSize: 2400,
          kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary),
      let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: 0.94)
    else { throw CocoaError(.fileReadCorruptFile) }
    let name = id.uuidString + ".jpg"
    try jpeg.write(to: AppPaths.artwork.appendingPathComponent(name), options: .atomic)
    albums[index].artworkFile = name
    albums[index].artworkPixelWidth = image.width
    albums[index].artworkPixelHeight = image.height
    albums[index].artworkVersion += 1
    artwork.invalidate()
    saveNow()
    onMetadataChanged?()
  }
  func removeArtwork(_ id: UUID) {
    guard let index = albums.firstIndex(where: { $0.id == id }) else { return }
    albums[index].artworkFile = nil
    albums[index].artworkVersion += 1
    artwork.invalidate()
    saveNow()
    onMetadataChanged?()
  }
  func removeAlbums(_ ids: Set<UUID>) {
    removeTracks(Set(albums.filter { ids.contains($0.id) }.flatMap(\.trackIDs)))
  }
  func removeTracks(_ ids: Set<UUID>) {
    guard !importing else {
      notice = "Finish or cancel the music import before removing music."
      return
    }
    let removed = ids.intersection(tracks.keys)
    guard !removed.isEmpty else { return }
    let affectedAlbums = Set(albums.filter { $0.trackIDs.contains { removed.contains($0) } }.map(\.id))
    onTracksRemoved?(removed)
    for id in removed {
      tracks[id] = nil
      try? FileManager.default.removeItem(at: Self.media.appendingPathComponent(id.uuidString))
    }
    for id in removed {
      try? FileManager.default.removeItem(
        at: AppPaths.root.appendingPathComponent("Lyrics/" + id.uuidString + ".lrc"))
    }
    for index in albums.indices where affectedAlbums.contains(albums[index].id) {
      albums[index].trackIDs.removeAll { removed.contains($0) }
    }
    let emptyAlbums = albums.filter { affectedAlbums.contains($0.id) && $0.trackIDs.isEmpty }
    for album in emptyAlbums {
      if let artworkFile = album.artworkFile {
        try? FileManager.default.removeItem(
          at: AppPaths.artwork.appendingPathComponent((artworkFile as NSString).lastPathComponent))
      }
    }
    albums.removeAll { affectedAlbums.contains($0.id) && $0.trackIDs.isEmpty }
    artwork.invalidate()
    saveNow()
  }
}

final class ArtworkStore: @unchecked Sendable {
  private let cache = NSCache<NSString, UIImage>()
  init() {
    cache.totalCostLimit = 80 * 1024 * 1024
    cache.countLimit = 180
  }
  func invalidate() { cache.removeAllObjects() }
  func thumbnail(_ album: Album, pixels: Int) async -> UIImage? {
    let key = "\(album.artworkKey)-\(pixels)" as NSString
    if let image = cache.object(forKey: key) { return image }
    guard let name = album.artworkFile else { return nil }
    let url = AppPaths.artwork.appendingPathComponent(name)
    let image = await Task.detached(priority: .utility) { () -> UIImage? in
      guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
        let image = CGImageSourceCreateThumbnailAtIndex(
          source, 0,
          [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
          ] as CFDictionary)
      else { return nil }
      return UIImage(cgImage: image)
    }.value
    if let image {
      cache.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * 4))
    }
    return image
  }
}
