import AppKit
import Foundation
import UniformTypeIdentifiers

struct ImportProgress: Equatable {
    var done: Int
    var total: Int
    var current: String
}

struct ImportReport: Identifiable {
    let id = UUID()
    var added = 0
    var albums = Set<UUID>()
    var duplicates: [String] = []
    var unsupported: [String] = []
    var failed: [String] = []
    var scanned = 0

    var isProblemOnly: Bool { added == 0 }

    var headline: String {
        if added == 0 && duplicates.isEmpty && unsupported.isEmpty && failed.isEmpty {
            return "No audio files found there."
        }
        if added == 0 && !duplicates.isEmpty && unsupported.isEmpty && failed.isEmpty {
            return duplicates.count == 1 ? "That track is already in your collection." : "Those \(duplicates.count) tracks are already in your collection."
        }
        if added == 0 { return "Nothing new was imported." }
        let t = added == 1 ? "1 track" : "\(added) tracks"
        let a = albums.count == 1 ? "1 album" : "\(albums.count) albums"
        return "Imported \(t) into \(a)."
    }

    var details: [String] {
        var out: [String] = []
        if !duplicates.isEmpty && added > 0 {
            out.append("\(duplicates.count) duplicate\(duplicates.count == 1 ? "" : "s") skipped")
        }
        if !unsupported.isEmpty {
            let names = unsupported.prefix(3).joined(separator: ", ")
            let more = unsupported.count > 3 ? " and \(unsupported.count - 3) more" : ""
            out.append("Unsupported format: \(names)\(more)")
        }
        if !failed.isEmpty {
            let names = failed.prefix(2).joined(separator: "; ")
            out.append("Couldn’t read: \(names)\(failed.count > 2 ? " …" : "")")
        }
        return out
    }
}

private struct LibraryFile: Codable {
    var version: Int
    var albums: [Album]
    var tracks: [Track]
}

/// Owns the collection: what's in it, how it's grouped, and how it's persisted.
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var albums: [Album] = []
    @Published private(set) var tracks: [UUID: Track] = [:]
    @Published private(set) var importProgress: ImportProgress?
    @Published var lastReport: ImportReport?
    @Published var notice: String?
    @Published private(set) var isGeneratingDemo = false

    let artwork: ArtworkStore
    private var albumIndex: [UUID: Int] = [:]
    private var trackToAlbum: [UUID: UUID] = [:]
    private var pendingSave: DispatchWorkItem?
    /// Lets the player drop tracks that left the collection.
    var onTracksRemoved: ((Set<UUID>) -> Void)?

    init(artwork: ArtworkStore) {
        self.artwork = artwork
    }

    // MARK: Lookup

    func album(_ id: UUID?) -> Album? {
        guard let id, let i = albumIndex[id] else { return nil }
        return albums[i]
    }

    func track(_ id: UUID?) -> Track? {
        guard let id else { return nil }
        return tracks[id]
    }

    func albumID(forTrack id: UUID) -> UUID? { trackToAlbum[id] }

    func tracks(of album: Album) -> [Track] { album.trackIDs.compactMap { tracks[$0] } }

    var hasDemoContent: Bool { albums.contains { $0.isDemo } }

    func totalDuration(_ album: Album) -> Double {
        album.trackIDs.reduce(0) { $0 + (tracks[$1]?.duration ?? 0) }
    }

    func visibleAlbums(sort: SortOrder, search: String) -> [Album] {
        var list = albums
        let q = search.normalizedKey
        if !q.isEmpty {
            list = list.filter { album in
                if album.title.normalizedKey.contains(q) || album.artist.normalizedKey.contains(q) { return true }
                return album.trackIDs.contains { id in
                    guard let t = tracks[id] else { return false }
                    return t.title.normalizedKey.contains(q) || t.artist.normalizedKey.contains(q)
                }
            }
        }
        func byArtist(_ a: Album, _ b: Album) -> Bool {
            let ka = a.artist.normalizedKey, kb = b.artist.normalizedKey
            if ka != kb { return ka.localizedStandardCompare(kb) == .orderedAscending }
            if a.year != b.year { return (a.year ?? 9999) < (b.year ?? 9999) }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
        switch sort {
        case .artist:
            list.sort(by: byArtist)
        case .title:
            list.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .recentlyAdded:
            list.sort { $0.dateAdded != $1.dateAdded ? $0.dateAdded > $1.dateAdded : byArtist($0, $1) }
        case .recentlyPlayed:
            list.sort {
                switch ($0.lastPlayed, $1.lastPlayed) {
                case let (a?, b?): return a > b
                case (_?, nil): return true
                case (nil, _?): return false
                default: return byArtist($0, $1)
                }
            }
        }
        return list
    }

    // MARK: Persistence

    func load() {
        let url = AppPaths.library
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let file = try JSONDecoder().decode(LibraryFile.self, from: data)
            tracks = Dictionary(uniqueKeysWithValues: file.tracks.map { ($0.id, $0) })
            albums = file.albums
            rebuildIndex()
        } catch {
            // Keep the unreadable file so nothing is lost, and start fresh.
            let backup = AppPaths.root.appendingPathComponent("Library-unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: backup)
            notice = "Your saved collection couldn’t be read, so Cover Flow started fresh. The old file was kept as \(backup.lastPathComponent)."
        }
    }

    func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.saveNow() }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        let file = LibraryFile(version: 1, albums: albums, tracks: Array(tracks.values))
        do {
            let data = try JSONEncoder().encode(file)
            try data.write(to: AppPaths.library, options: .atomic)
        } catch {
            notice = "Couldn’t save your collection: \(error.localizedDescription)"
        }
    }

    private func rebuildIndex() {
        albumIndex = [:]
        trackToAlbum = [:]
        for (i, a) in albums.enumerated() {
            albumIndex[a.id] = i
            for t in a.trackIDs { trackToAlbum[t] = a.id }
        }
    }

    // MARK: Import

    func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.title = "Import Music"
        panel.message = "Choose audio files or folders. Cover Flow reads them where they are — nothing is copied or moved."
        panel.prompt = "Import"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            let urls = panel.urls
            MainActor.assumeIsolated { self?.importURLs(urls) }
        }
    }

    func importURLs(_ urls: [URL]) {
        guard importProgress == nil else {
            notice = "An import is already running. Try again when it finishes."
            return
        }
        importProgress = ImportProgress(done: 0, total: 0, current: "Looking for audio files…")
        Task { await runImport(urls) }
    }

    nonisolated private static func enumerate(_ urls: [URL]) -> (audio: [URL], unsupported: [URL]) {
        var audio: [URL] = []
        var unsupported: [URL] = []
        let fm = FileManager.default
        func consider(_ url: URL, explicit: Bool) {
            let ext = url.pathExtension.lowercased()
            if MetadataReader.supportedExtensions.contains(ext) {
                audio.append(url)
            } else if MetadataReader.knownUnsupported.contains(ext) {
                unsupported.append(url)
            } else if explicit {
                if let type = UTType(filenameExtension: ext), type.conforms(to: .audio) || type.conforms(to: .audiovisualContent) {
                    unsupported.append(url)
                } else if !ext.isEmpty {
                    unsupported.append(url)
                }
            }
        }
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let keys: [URLResourceKey] = [.isRegularFileKey]
                guard let e = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                for case let file as URL in e {
                    let resolved = file.resolvingSymlinksInPath()
                    if (try? resolved.resourceValues(forKeys: Set(keys)).isRegularFile) == true {
                        consider(file, explicit: false)
                    }
                }
            } else {
                consider(url, explicit: true)
            }
        }
        audio.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return (audio, unsupported)
    }

    private func runImport(_ urls: [URL]) async {
        let found = await Task.detached(priority: .userInitiated) { Self.enumerate(urls) }.value
        var report = ImportReport()
        report.unsupported = found.unsupported.map(\.lastPathComponent)
        report.scanned = found.audio.count + found.unsupported.count

        var knownPaths = Set(tracks.values.map { $0.fileURL.resolvingSymlinksInPath().standardizedFileURL.path })
        var knownFingerprints = Set(tracks.values.map(\.fingerprint))
        let total = found.audio.count
        var touchedAlbums = Set<UUID>()

        for (i, url) in found.audio.enumerated() {
            importProgress = ImportProgress(done: i, total: total, current: url.lastPathComponent)
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            if knownPaths.contains(path) {
                report.duplicates.append(url.lastPathComponent)
                continue
            }
            do {
                let meta = try await MetadataReader.read(url)
                let fingerprint = Self.fingerprint(meta)
                if knownFingerprints.contains(fingerprint) {
                    report.duplicates.append(url.lastPathComponent)
                    continue
                }
                knownPaths.insert(path)
                knownFingerprints.insert(fingerprint)
                let albumID = await add(meta: meta, url: url, isDemo: false)
                touchedAlbums.insert(albumID)
                report.albums.insert(albumID)
                report.added += 1
            } catch MetadataError.notPlayable {
                report.unsupported.append(url.lastPathComponent)
            } catch {
                report.failed.append("\(url.lastPathComponent) (\(error.localizedDescription))")
            }
        }
        for id in touchedAlbums { finalizeAlbum(id) }
        rebuildIndex()
        saveNow()
        importProgress = nil
        lastReport = report
        if report.added > 0 { Announcer.announce(report.headline) }
    }

    nonisolated static func fingerprint(_ m: ParsedMetadata) -> String {
        let d = Int(m.duration.rounded())
        return [m.title?.normalizedKey ?? "", m.artist?.normalizedKey ?? "", m.album?.normalizedKey ?? "", String(d)].joined(separator: "|")
    }

    /// Adds one track, creating or extending its album. Returns the album id.
    @discardableResult
    private func add(meta: ParsedMetadata, url: URL, isDemo: Bool) async -> UUID {
        let artist = meta.artist ?? meta.albumArtist ?? "Unknown Artist"
        let folder = url.deletingLastPathComponent()
        let albumTitle = meta.album ?? folder.lastPathComponent
        let groupKey: String
        if let album = meta.album {
            let who = meta.albumArtist?.normalizedKey ?? "dir:" + folder.path
            groupKey = "album:" + album.normalizedKey + "|" + who
        } else {
            groupKey = "folder:" + folder.path
        }

        let track = Track(
            id: UUID(), fileURL: url, title: meta.title ?? url.deletingPathExtension().lastPathComponent,
            artist: artist, albumTitle: albumTitle, albumArtist: meta.albumArtist,
            trackNumber: meta.trackNumber, discNumber: meta.discNumber, duration: meta.duration,
            year: meta.year, genre: meta.genre, dateAdded: Date(), isDemo: isDemo,
            missingMetadata: meta.usedFallback, fingerprint: Self.fingerprint(meta))
        tracks[track.id] = track

        let albumID: UUID
        if let idx = albums.firstIndex(where: { $0.groupKey == groupKey }) {
            albums[idx].trackIDs.append(track.id)
            if albums[idx].year == nil { albums[idx].year = meta.year }
            if albums[idx].genre == nil { albums[idx].genre = meta.genre }
            albumID = albums[idx].id
        } else {
            let album = Album(
                id: UUID(), groupKey: groupKey, title: albumTitle, artist: meta.albumArtist ?? artist,
                year: meta.year, genre: meta.genre, trackIDs: [track.id], artworkFile: nil,
                artworkPixelWidth: nil, artworkPixelHeight: nil, artworkVersion: 0, tintHex: nil,
                dateAdded: Date(), lastPlayed: nil, isDemo: isDemo, missingMetadata: meta.album == nil,
                userEdited: false)
            albums.append(album)
            albumID = album.id
            albumIndex[album.id] = albums.count - 1
        }
        trackToAlbum[track.id] = albumID

        if let data = meta.artwork, let i = albums.firstIndex(where: { $0.id == albumID }), albums[i].artworkFile == nil {
            let store = artwork
            let saved = await Task.detached(priority: .utility) { try? store.save(data: data, albumID: albumID) }.value
            if let saved, let j = albums.firstIndex(where: { $0.id == albumID }) {
                albums[j].artworkFile = saved.file
                albums[j].artworkPixelWidth = saved.pixelWidth
                albums[j].artworkPixelHeight = saved.pixelHeight
                albums[j].tintHex = saved.tintHex
                albums[j].artworkVersion += 1
            }
        }
        return albumID
    }

    /// Orders tracks by disc and track number and settles the album's display artist.
    private func finalizeAlbum(_ id: UUID) {
        guard let i = albums.firstIndex(where: { $0.id == id }) else { return }
        var album = albums[i]
        let list = album.trackIDs.compactMap { tracks[$0] }
        album.trackIDs = list.sorted { a, b in
            let ka = a.sortKey, kb = b.sortKey
            if ka.0 != kb.0 { return ka.0 < kb.0 }
            if ka.1 != kb.1 { return ka.1 < kb.1 }
            return ka.2.localizedStandardCompare(kb.2) == .orderedAscending
        }.map(\.id)
        if !album.userEdited {
            if let aa = list.compactMap(\.albumArtist).first {
                album.artist = aa
            } else {
                let artists = Set(list.map { $0.artist.normalizedKey })
                if artists.count > 1 {
                    album.artist = "Various Artists"
                } else if let first = list.first {
                    album.artist = first.artist
                }
            }
        }
        albums[i] = album
    }

    // MARK: Editing

    struct TrackEdit: Identifiable, Hashable {
        let id: UUID
        var title: String
        var trackNumber: String
        var discNumber: String
    }

    func updateAlbum(_ id: UUID, title: String, artist: String, year: String, genre: String, trackEdits: [TrackEdit]) {
        guard let i = albumIndex[id] else { return }
        albums[i].title = title.nonEmpty ?? albums[i].title
        albums[i].artist = artist.nonEmpty ?? albums[i].artist
        albums[i].year = Int(year.trimmingCharacters(in: .whitespaces))
        albums[i].genre = genre.nonEmpty
        albums[i].userEdited = true
        albums[i].missingMetadata = false
        for edit in trackEdits {
            guard var t = tracks[edit.id] else { continue }
            t.title = edit.title.nonEmpty ?? t.title
            t.trackNumber = Int(edit.trackNumber.trimmingCharacters(in: .whitespaces))
            t.discNumber = Int(edit.discNumber.trimmingCharacters(in: .whitespaces))
            t.albumTitle = albums[i].title
            if t.artist == "Unknown Artist" && albums[i].artist != "Various Artists" { t.artist = albums[i].artist }
            t.missingMetadata = false
            tracks[t.id] = t
        }
        finalizeAlbum(id)
        rebuildIndex()
        scheduleSave()
    }

    func chooseReplacementArtwork(for id: UUID) {
        let panel = NSOpenPanel()
        panel.title = "Choose Artwork"
        panel.message = "Pick an image to use as this album’s cover. The largest version you have will look best in Album View."
        panel.prompt = "Use Image"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self?.replaceArtwork(id, with: url) }
        }
    }

    func replaceArtwork(_ id: UUID, with url: URL) {
        Task {
            let store = artwork
            let result: Result<SavedArtwork, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    let data = try Data(contentsOf: url)
                    return .success(try store.save(data: data, albumID: id))
                } catch {
                    return .failure(error)
                }
            }.value
            switch result {
            case .success(let saved):
                guard let i = albumIndex[id] else { return }
                albums[i].artworkFile = saved.file
                albums[i].artworkPixelWidth = saved.pixelWidth
                albums[i].artworkPixelHeight = saved.pixelHeight
                albums[i].tintHex = saved.tintHex
                albums[i].artworkVersion += 1
                scheduleSave()
                if saved.pixelWidth < 600 {
                    notice = "Artwork updated. It’s \(saved.pixelWidth)×\(saved.pixelHeight) pixels, so it will appear smaller in Album View to stay sharp."
                }
            case .failure(let error):
                notice = "Couldn’t use that image: \(error.localizedDescription)"
            }
        }
    }

    func removeArtwork(_ id: UUID) {
        guard let i = albumIndex[id] else { return }
        artwork.remove(file: albums[i].artworkFile)
        albums[i].artworkFile = nil
        albums[i].tintHex = nil
        albums[i].artworkVersion += 1
        scheduleSave()
    }

    /// Removes albums from the collection. Audio files on disk are not touched (except generated demo audio).
    func removeAlbums(_ ids: Set<UUID>, deleteDemoAudio: Bool = true) {
        let removing = albums.filter { ids.contains($0.id) }
        var removedTracks = Set<UUID>()
        for album in removing {
            artwork.remove(file: album.artworkFile)
            for t in album.trackIDs {
                if deleteDemoAudio, let track = tracks[t], track.isDemo { try? FileManager.default.removeItem(at: track.fileURL) }
                tracks[t] = nil
                removedTracks.insert(t)
            }
        }
        albums.removeAll { ids.contains($0.id) }
        rebuildIndex()
        saveNow()
        if !removedTracks.isEmpty { onTracksRemoved?(removedTracks) }
    }

    func removeAll() {
        removeAlbums(Set(albums.map(\.id)))
    }

    func markPlayed(trackID: UUID) {
        guard let a = trackToAlbum[trackID], let i = albumIndex[a] else { return }
        albums[i].lastPlayed = Date()
        scheduleSave()
    }

    func fileExists(_ track: Track) -> Bool {
        FileManager.default.fileExists(atPath: track.fileURL.path)
    }

    // MARK: Demo collection

    func addDemoCollection() {
        guard !isGeneratingDemo else { return }
        isGeneratingDemo = true
        Task {
            let store = artwork
            let output = await Task.detached(priority: .userInitiated) { () -> [DemoLibrary.GeneratedAlbum]? in
                try? DemoLibrary.generate(into: AppPaths.demo, artwork: store)
            }.value
            isGeneratingDemo = false
            guard let output else {
                notice = "The demo collection couldn’t be created."
                return
            }
            // Replace any previous demo content.
            removeAlbums(Set(albums.filter(\.isDemo).map(\.id)), deleteDemoAudio: false)
            for generated in output {
                var album = generated.album
                for t in generated.tracks { tracks[t.id] = t }
                album.trackIDs = generated.tracks.map(\.id)
                albums.append(album)
            }
            rebuildIndex()
            saveNow()
        }
    }

    func removeDemoCollection() {
        removeAlbums(Set(albums.filter(\.isDemo).map(\.id)))
    }
}
