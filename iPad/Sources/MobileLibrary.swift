import Combine
import CryptoKit
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

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
  /// What “Find Back Covers & Disc Art” is doing, while it runs.
  @Published var extraArtProgress: String?
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
    var extraChecked = Set<String>()
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
        // Back covers, disc art and booklets beside the original file or in its tags.
        let disc = max(1, meta.discNumber ?? 1)
        let extraKey = "\(albums[albumIndex].id)|\(disc)|\(source.deletingLastPathComponent().path)"
        if extraChecked.insert(extraKey).inserted {
          await addLocalExtraArtwork(albumID: albums[albumIndex].id, audio: source, disc: disc)
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
      artwork.removeExtras(album.extraImages ?? [])
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
  let cache = NSCache<NSString, UIImage>()
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

// MARK: Back covers, disc art and booklets (as on the Mac)

extension ArtworkStore {
  func fileURL(_ name: String) -> URL { AppPaths.artwork.appendingPathComponent((name as NSString).lastPathComponent) }

  /// Writes a back cover, disc or booklet image as "<album>_<kind><n>-<uuid>.ext",
  /// the same names the Mac uses. Safe off the main thread.
  func saveExtra(data: Data, albumID: UUID, kind: AlbumImageKind, disc: Int? = nil) throws -> AlbumImage {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0,
      let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    else { throw CocoaError(.fileReadCorruptFile) }
    var width = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
    var height = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
    if let orientation = props[kCGImagePropertyOrientation] as? Int, orientation >= 5 { swap(&width, &height) }
    guard width > 0, height > 0 else { throw CocoaError(.fileReadCorruptFile) }
    let type = (CGImageSourceGetType(source) as String?).flatMap { UTType($0) }
    let ext = type?.preferredFilenameExtension ?? "img"
    let label = kind == .back ? "back" : kind == .disc ? "disc\(disc ?? 1)" : "booklet\(disc ?? 1)"
    let name = "\(albumID.uuidString)_\(label)-\(UUID().uuidString).\(ext)"
    try FileManager.default.createDirectory(at: AppPaths.artwork, withIntermediateDirectories: true)
    try data.write(to: fileURL(name), options: .atomic)
    return AlbumImage(kind: kind, file: name, disc: kind == .back ? nil : (disc ?? 1), pixelWidth: width, pixelHeight: height)
  }

  func removeExtras(_ images: [AlbumImage]) {
    for image in images {
      try? FileManager.default.removeItem(at: fileURL(image.file))
      for pixels in [256, 512, 900, 1400, 2000] { cache.removeObject(forKey: "\(image.file)-\(pixels)" as NSString) }
    }
  }

  /// Rounds a point size to a few cache sizes so scrolling reuses decoded images.
  static func bucket(_ pixels: CGFloat) -> Int {
    [256, 512, 900, 1400, 2000].first { CGFloat($0) >= pixels } ?? 2000
  }

  func cachedExtra(_ image: AlbumImage, pixels: Int) -> UIImage? {
    cache.object(forKey: "\(image.file)-\(pixels)" as NSString)
  }

  func extra(_ image: AlbumImage, pixels: Int) async -> UIImage? {
    let key = "\(image.file)-\(pixels)" as NSString
    if let cached = cache.object(forKey: key) { return cached }
    let url = fileURL(image.file)
    let decoded = await Task.detached(priority: .utility) { () -> UIImage? in
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
    if let decoded { cache.setObject(decoded, forKey: key, cost: Int(decoded.size.width * decoded.size.height * 4)) }
    return decoded
  }
}

extension LibraryStore {
  /// Disc numbers of the album's tracks (1 when untagged).
  func discNumbers(of album: Album) -> Set<Int> {
    let discs = Set(tracks(of: album).map { max(1, $0.discNumber ?? 1) })
    return discs.isEmpty ? [1] : discs
  }

  /// Whether the album still lacks a back cover or art for one of its discs.
  func needsExtraArt(_ album: Album) -> Bool {
    guard !album.isDemo else { return false }
    let have = Set(album.discImages.compactMap(\.disc))
    return album.backImage == nil || !discNumbers(of: album).isSubset(of: have)
  }

  /// Back, disc and booklet images beside `audio` or in its tags, for kinds and discs
  /// the album doesn't have yet. Returns how many were added.
  @discardableResult
  func addLocalExtraArtwork(albumID: UUID, audio: URL, disc: Int) async -> Int {
    guard let album = album(albumID) else { return 0 }
    let have = Set((album.extraImages ?? []).map { "\($0.kind.rawValue)\($0.disc ?? 0)" })
    let store = artwork
    let saved = await Task.detached(priority: .utility) { () -> [AlbumImage] in
      ExtraArtworkReader.read(for: audio, trackDisc: disc)
        .filter { !have.contains("\($0.kind.rawValue)\($0.disc ?? 0)") }
        .compactMap { try? store.saveExtra(data: $0.data, albumID: albumID, kind: $0.kind, disc: $0.disc) }
    }.value
    guard !saved.isEmpty else { return 0 }
    guard let index = albums.firstIndex(where: { $0.id == albumID }) else {
      store.removeExtras(saved)
      return 0
    }
    albums[index].extraImages = (albums[index].extraImages ?? []) + saved
    saveNow()
    return saved.count
  }

  /// Saves images for an album, replacing the ones it had of the same kind and disc
  /// (or booklet page). Returns how many were saved.
  @discardableResult
  func replaceExtraImages(_ id: UUID, with items: [(kind: AlbumImageKind, disc: Int?, data: Data)]) async -> Int {
    guard album(id) != nil, !items.isEmpty else { return 0 }
    let store = artwork
    let payload = items.map { ($0.kind, $0.disc, $0.data) }
    let saved = await Task.detached(priority: .userInitiated) { () -> [AlbumImage] in
      payload.compactMap { try? store.saveExtra(data: $0.2, albumID: id, kind: $0.0, disc: $0.1) }
    }.value
    guard let index = albums.firstIndex(where: { $0.id == id }) else {
      store.removeExtras(saved)
      return 0
    }
    let replaced = Set(saved.map { "\($0.kind.rawValue)\($0.disc ?? 0)" })
    let old = (albums[index].extraImages ?? []).filter { replaced.contains("\($0.kind.rawValue)\($0.disc ?? 0)") }
    albums[index].extraImages = (albums[index].extraImages ?? []).filter {
      !replaced.contains("\($0.kind.rawValue)\($0.disc ?? 0)")
    } + saved
    store.removeExtras(old)
    saveNow()
    return saved.count
  }

  /// Removes all of the album's back, disc and booklet art (audio files untouched).
  func removeExtraImages(_ id: UUID) {
    guard let index = albums.firstIndex(where: { $0.id == id }), let images = albums[index].extraImages else { return }
    artwork.removeExtras(images)
    albums[index].extraImages = nil
    saveNow()
  }

  /// Removes particular images (a nil disc matches disc 1).
  func removeExtraImages(_ id: UUID, only items: [(kind: AlbumImageKind, disc: Int?)]) {
    guard let index = albums.firstIndex(where: { $0.id == id }), let images = albums[index].extraImages,
      !items.isEmpty
    else { return }
    func key(_ kind: AlbumImageKind, _ disc: Int?) -> String { "\(kind.rawValue)\(kind == .back ? 0 : (disc ?? 1))" }
    let keys = Set(items.map { key($0.kind, $0.disc) })
    let gone = images.filter { keys.contains(key($0.kind, $0.disc)) }
    guard !gone.isEmpty else { return }
    artwork.removeExtras(gone)
    let rest = images.filter { image in !gone.contains { $0.file == image.file } }
    albums[index].extraImages = rest.isEmpty ? nil : rest
    saveNow()
  }

  /// Booklet pages chosen by hand, in order, replace the album's booklet.
  func setBookletPages(_ id: UUID, pages: [Data]) async -> Int {
    guard let album = album(id), !pages.isEmpty else { return 0 }
    let old = album.bookletPages.compactMap(\.disc)
    let saved = await replaceExtraImages(
      id, with: pages.prefix(40).enumerated().map { (kind: AlbumImageKind.booklet, disc: Optional($0.offset + 1), data: $0.element) })
    removeExtraImages(id, only: old.filter { $0 > min(40, pages.count) }.map { (kind: AlbumImageKind.booklet, disc: Optional($0)) })
    return saved
  }

  /// Fills in missing back covers and disc art for the albums: their own files first
  /// (for music imported before this existed, nothing is left to read, since only the
  /// audio was copied), then online — Cover Art Archive, TheAudioDB, and fanart.tv
  /// with a key — for albums MusicBrainz matches confidently. Existing art is kept.
  func findExtraArt(_ ids: [UUID]) {
    guard extraArtProgress == nil, !importing else {
      notice = "Cover Flow is busy. Try again when the current import or search finishes."
      return
    }
    let targets = ids.compactMap { album($0) }.filter { needsExtraArt($0) }
    guard !targets.isEmpty else {
      notice = ids.count == 1
        ? "This album already has a back cover and disc art. Use Find Artwork Online… to replace them."
        : "Every album already has a back cover and disc art."
      return
    }
    let fanartKey = ExtraArtSettings.fanartKey
    extraArtProgress = "Finding back & disc art…"
    Task {
      var improved = 0, unmatched = 0, failed = 0
      search: for (n, target) in targets.enumerated() {
        extraArtProgress = "Back & disc art \(n + 1) of \(targets.count): \(target.title)"
        guard let album = album(target.id), needsExtraArt(album) else { continue }
        do {
          if let count = try await downloadExtraArt(album, fanartKey: fanartKey) {
            if count > 0 { improved += 1 }
          } else {
            unmatched += 1
          }
        } catch {
          failed += 1
          if case MusicLookupError.rateLimited = error { break search }
        }
      }
      extraArtProgress = nil
      var message = targets.count == 1
        ? (improved == 1
          ? "Added back cover or disc art to “\(targets[0].title)”. Flip the cover in Cover Flow to see it."
          : unmatched == 1
            ? "Couldn’t find “\(targets[0].title)” on MusicBrainz with that title and artist. Try Find Artwork Online… to search by hand."
            : "No back cover or disc art found for “\(targets[0].title)”.")
        : "Added back covers or disc art to \(improved) of \(targets.count) albums."
      if targets.count > 1 && unmatched > 0 { message += " \(unmatched) couldn’t be matched on MusicBrainz." }
      if failed > 0 { message += " \(failed) lookup\(failed == 1 ? "" : "s") failed; try again later." }
      notice = message
    }
  }

  /// Downloads online back/disc art the album lacks. Nil when no confident match.
  private func downloadExtraArt(_ album: Album, fanartKey: String?) async throws -> Int? {
    let client = MusicLookupClient.shared
    guard let match = try await client.bestMatch(title: album.title, artist: album.artist) else { return nil }
    let haveDiscs = Set(album.discImages.compactMap(\.disc))
    let albumDiscs = discNumbers(of: album)
    var found = await client.albumExtras(match, fanartKey: fanartKey)
    if albumDiscs == [1], !found.contains(where: { $0.kind == .disc && $0.disc == 1 }),
      let first = found.first(where: { $0.kind == .disc })
    {
      found.append(CoverArtExtra(kind: .disc, disc: 1, url: first.url, source: first.source))
    }
    let wanted = found.filter { extra in
      extra.kind == .back
        ? album.backImage == nil
        : extra.kind == .disc && albumDiscs.contains(extra.disc ?? 1) && !haveDiscs.contains(extra.disc ?? 1)
    }
    var images: [(kind: AlbumImageKind, disc: Int?, data: Data)] = []
    for extra in wanted {
      try Task.checkCancellation()
      if let data = try? await client.extraImage(extra) { images.append((extra.kind, extra.disc, data)) }
    }
    return images.isEmpty ? 0 : await replaceExtraImages(album.id, with: images)
  }
}
