import Combine
import SwiftUI
import UniformTypeIdentifiers

/// What lyrics a track has.
enum LyricsStatus: Equatable {
  case synced, plain, none
  var label: String {
    switch self {
    case .synced: return "Synced"
    case .plain: return "Plain"
    case .none: return "No lyrics"
    }
  }
  var icon: String {
    switch self {
    case .synced: return "text.badge.checkmark"
    case .plain: return "text.alignleft"
    case .none: return "minus.circle"
    }
  }
}

/// Which tracks “Get Lyrics” looks up, as in Lyripass.
enum LyricsFetchScope: String, CaseIterable, Identifiable {
  case missing, missingSynced, all
  var id: String { rawValue }
  var label: String {
    switch self {
    case .missing: return "Tracks Without Lyrics"
    case .missingSynced: return "Tracks Without Synced Lyrics"
    case .all: return "All Tracks"
    }
  }
}

/// Lyripass's library features for Cover Flow on iPhone and iPad: which tracks have
/// lyrics, finding lyrics for many tracks at once on LRCLIB, and exporting them.
@MainActor final class MobileLyricsLibrary: ObservableObject {
  @Published private(set) var status: [UUID: LyricsStatus] = [:]
  @Published private(set) var scanning = false
  /// “Get Lyrics” progress, while it runs.
  @Published private(set) var progress: (done: Int, total: Int, current: String)?
  @Published var notice: String?
  let directory = AppPaths.root.appendingPathComponent("Lyrics", isDirectory: true)
  private var work: Task<Void, Never>?
  private var scanToken = 0

  func status(of id: UUID) -> LyricsStatus { status[id] ?? .none }

  /// Re-reads which tracks have synced, plain or no lyrics.
  func refresh(_ tracks: [Track]) {
    scanToken += 1
    let token = scanToken
    scanning = true
    let directory = directory
    let items = tracks.map { ($0.id, $0.fileURL) }
    Task {
      let result = await Task.detached(priority: .utility) { () -> [UUID: LyricsStatus] in
        var found: [UUID: LyricsStatus] = [:]
        for (id, url) in items {
          found[id] = Self.read(trackID: id, audio: url, directory: directory)
        }
        return found
      }.value
      guard token == scanToken else { return }
      status = result
      scanning = false
    }
  }

  func update(_ id: UUID, audio: URL) {
    let directory = directory
    Task {
      let value = await Task.detached(priority: .utility) { Self.read(trackID: id, audio: audio, directory: directory) }.value
      status[id] = value
    }
  }

  nonisolated static func read(trackID: UUID, audio: URL, directory: URL) -> LyricsStatus {
    guard let loaded = try? LyricsStore.find(trackID: trackID, audioURL: audio, directory: directory) else { return .none }
    return loaded.document.isSynced ? .synced : loaded.document.plainText.isEmpty ? .none : .plain
  }

  var running: Bool { progress != nil }

  /// Looks up lyrics on LRCLIB for every track in scope, keeping the best match whose
  /// length is within a few seconds of the track. Synced lyrics are never replaced by
  /// plain ones.
  func fetch(_ scope: LyricsFetchScope, tracks: [Track], onSaved: @escaping (UUID) -> Void) {
    guard !running else { return }
    let targets = tracks.filter { track in
      guard !track.isDemo else { return false }
      switch scope {
      case .all: return true
      case .missing: return status(of: track.id) == .none
      case .missingSynced: return status(of: track.id) != .synced
      }
    }
    guard !targets.isEmpty else {
      notice = scope == .all ? "There are no tracks to look up." : "Every track already has \(scope == .missing ? "" : "synced ")lyrics."
      return
    }
    progress = (0, targets.count, targets[0].title)
    let directory = directory
    work = Task {
      var synced = 0, plain = 0, missing = 0, failed = 0
      for (n, track) in targets.enumerated() {
        if Task.isCancelled { break }
        progress = (n, targets.count, track.title)
        do {
          let matches = try await MusicLookupClient.shared.lyrics(
            title: track.title, artist: track.artist, duration: track.duration)
          guard let best = Self.bestMatch(matches, for: track) else {
            missing += 1
            continue
          }
          let had = status(of: track.id)
          if !best.isSynced && had == .synced { continue }
          if !best.isSynced && had == .plain && scope != .all { continue }
          _ = try await Task.detached(priority: .utility) {
            try LyricsStore.importText(best.text, trackID: track.id, directory: directory)
          }.value
          status[track.id] = best.isSynced ? .synced : .plain
          if best.isSynced { synced += 1 } else { plain += 1 }
          onSaved(track.id)
        } catch is CancellationError {
          break
        } catch MusicLookupError.noResults {
          missing += 1
        } catch {
          failed += 1
          if case MusicLookupError.rateLimited = error { break }
        }
      }
      let cancelled = Task.isCancelled
      progress = nil
      var message = cancelled ? "Stopped. " : ""
      message += "Found synced lyrics for \(synced) and plain lyrics for \(plain) of \(targets.count) track\(targets.count == 1 ? "" : "s")."
      if missing > 0 { message += " \(missing) had no match on LRCLIB." }
      if failed > 0 { message += " \(failed) lookup\(failed == 1 ? "" : "s") failed; try again later." }
      notice = message
    }
  }

  func cancel() { work?.cancel() }

  /// The first match (LRCLIB results come sorted by closeness of length, synced first)
  /// that is within three seconds of the track, or any match for tracks of unknown length.
  nonisolated static func bestMatch(_ matches: [LyricMatch], for track: Track) -> LyricMatch? {
    guard track.duration.isFinite, track.duration > 0 else { return matches.first }
    return matches.first { abs($0.duration - track.duration) <= 3 }
  }

  /// A file name like “Artist - Title.lrc”, without characters Files won't accept.
  nonisolated static func fileName(for track: Track, ext: String) -> String {
    let base = "\(track.artist) - \(track.title)"
      .components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>")).joined(separator: "-")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return String((base.isEmpty ? "Lyrics" : base).prefix(180)) + "." + ext
  }

  /// The raw text of a track's lyric file, if it has one.
  nonisolated static func text(for track: Track, directory: URL) -> String? {
    guard let loaded = try? LyricsStore.find(trackID: track.id, audioURL: track.fileURL, directory: directory),
      let data = try? Data(contentsOf: loaded.source)
    else { return nil }
    let utf16 = data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF])
    return String(data: data, encoding: utf16 ? .utf16 : .utf8)
  }

  /// Lyrics of the tracks, as LRC (synced, or plain when that's all there is) or plain text.
  nonisolated static func exportFiles(_ tracks: [Track], plainText: Bool, directory: URL) -> [String: Data] {
    var files: [String: Data] = [:]
    for track in tracks {
      guard let raw = text(for: track, directory: directory) else { continue }
      let draft = LyricsDraft.parse(raw)
      let text = plainText ? draft.plainText + "\n" : (draft.isSynced ? draft.lrc() : draft.plainText + "\n")
      let ext = plainText ? "txt" : "lrc"
      let first = fileName(for: track, ext: ext)
      var name = first
      var n = 2
      while files[name] != nil {
        name = String(first.dropLast(ext.count + 1)) + " \(n)." + ext
        n += 1
      }
      files[name] = Data(text.utf8)
    }
    return files
  }
}

/// A folder of lyric files, for exporting to Files.
struct LyricsFolderDocument: FileDocument {
  static var readableContentTypes: [UTType] { [.folder] }
  var files: [String: Data]
  init(files: [String: Data]) { self.files = files }
  init(configuration: ReadConfiguration) throws { files = [:] }
  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(directoryWithFileWrappers: files.mapValues { FileWrapper(regularFileWithContents: $0) })
  }
}

/// Lyripass's library: every track with its lyrics status, finding lyrics for many
/// tracks at once, editing, and exporting the lyrics to Files.
struct MobileLyricsLibraryView: View {
  @EnvironmentObject private var library: LibraryStore
  @EnvironmentObject private var player: PlayerEngine
  @EnvironmentObject private var lyrics: LyricsStore
  @EnvironmentObject private var store: MobileLyricsLibrary
  @Environment(\.dismiss) private var dismiss
  @State private var filter: Filter = .all
  @State private var search = ""
  @State private var downloadTrack: Track?
  @State private var editTrack: Track?
  @State private var exporting = false
  @State private var exportDocument = LyricsFolderDocument(files: [:])
  @State private var preparingExport = false

  enum Filter: String, CaseIterable, Identifiable {
    case all = "All", synced = "Synced", plain = "Plain", missing = "Missing"
    var id: String { rawValue }
  }

  private var albums: [(Album, [Track])] {
    let query = search.normalizedKey
    return library.visibleAlbums(sort: .artist, search: "").compactMap { album in
      let tracks = library.tracks(of: album).filter { track in
        guard query.isEmpty || [track.title, track.artist, album.title].contains(where: { $0.normalizedKey.contains(query) })
        else { return false }
        switch filter {
        case .all: return true
        case .synced: return store.status(of: track.id) == .synced
        case .plain: return store.status(of: track.id) == .plain
        case .missing: return store.status(of: track.id) == .none
        }
      }
      return tracks.isEmpty ? nil : (album, tracks)
    }
  }

  private var allTracks: [Track] { library.albums.flatMap { library.tracks(of: $0) } }

  private var counts: (synced: Int, plain: Int, none: Int) {
    allTracks.reduce(into: (0, 0, 0)) { total, track in
      switch store.status(of: track.id) {
      case .synced: total.0 += 1
      case .plain: total.1 += 1
      case .none: total.2 += 1
      }
    }
  }

  var body: some View {
    NavigationStack {
      List {
        Section {
          let c = counts
          HStack(spacing: 18) {
            summary(c.synced, "synced", "text.badge.checkmark")
            summary(c.plain, "plain", "text.alignleft")
            summary(c.none, "without", "minus.circle")
          }
          .font(.callout)
          if let progress = store.progress {
            VStack(alignment: .leading, spacing: 6) {
              HStack {
                Text("Getting lyrics \(progress.done + 1) of \(progress.total): \(progress.current)")
                  .font(.caption).lineLimit(1)
                Spacer()
                Button("Stop") { store.cancel() }.font(.caption)
              }
              ProgressView(value: Double(progress.done), total: Double(max(1, progress.total)))
            }
          }
          Picker("Show", selection: $filter) {
            ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
          }.pickerStyle(.segmented)
        }
        ForEach(albums, id: \.0.id) { album, tracks in
          Section("\(album.title) — \(album.artist)") {
            ForEach(tracks) { track in row(track, album: album) }
          }
        }
      }
      .overlay {
        if library.albums.isEmpty {
          ContentUnavailableView("No music yet", systemImage: "music.note", description: Text("Import music to find its lyrics."))
        } else if albums.isEmpty {
          ContentUnavailableView.search(text: search)
        }
      }
      .searchable(text: $search, prompt: "Tracks, artists, albums")
      .navigationTitle("Lyrics Library")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
        ToolbarItem(placement: .primaryAction) {
          Menu {
            Section("Get Lyrics from LRCLIB for") {
              ForEach(LyricsFetchScope.allCases) { scope in
                Button(scope.label) { fetch(scope) }
              }
            }
          } label: {
            Label("Get Lyrics", systemImage: "arrow.down.circle")
          }.disabled(store.running || library.albums.isEmpty)
        }
        ToolbarItem(placement: .topBarTrailing) {
          Menu {
            Button("Export Synced (.lrc)…") { export(plain: false) }
            Button("Export Plain (.txt)…") { export(plain: true) }
          } label: {
            Label("Export", systemImage: "square.and.arrow.up")
          }.disabled(preparingExport || counts.synced + counts.plain == 0)
        }
      }
      .refreshable { store.refresh(allTracks) }
      .task { store.refresh(allTracks) }
      .sheet(item: $downloadTrack) { track in
        LyricsDownloadView(track: track) { match in
          guard library.track(track.id) != nil else { throw MusicLookupError.itemRemoved }
          try await lyrics.importDownloaded(match.text, for: track)
          store.update(track.id, audio: track.fileURL)
        }
      }
      .sheet(item: $editTrack) { track in
        MobileLyricsEditor(track: track) { store.update(track.id, audio: track.fileURL) }
      }
      .fileExporter(
        isPresented: $exporting, document: exportDocument, contentType: .folder,
        defaultFilename: "Cover Flow Lyrics"
      ) { result in
        if case .failure(let error) = result { store.notice = error.localizedDescription }
      }
      .alert(
        "Lyrics", isPresented: Binding(get: { store.notice != nil }, set: { if !$0 { store.notice = nil } })
      ) {
        Button("OK") { store.notice = nil }
      } message: {
        Text(store.notice ?? "")
      }
    }
  }

  private func summary(_ count: Int, _ label: String, _ icon: String) -> some View {
    Label("\(count) \(label)", systemImage: icon).foregroundStyle(.secondary)
  }

  private func row(_ track: Track, album: Album) -> some View {
    let status = store.status(of: track.id)
    return HStack(spacing: 12) {
      Image(systemName: status.icon)
        .foregroundStyle(status == .synced ? Color.green : status == .plain ? Color.orange : Color.secondary)
        .frame(width: 24)
        .accessibilityLabel(status.label)
      VStack(alignment: .leading, spacing: 2) {
        Text(track.title).lineLimit(1)
        Text("\(track.artist) · \(formatTime(track.duration))").font(.caption).foregroundStyle(.secondary).lineLimit(1)
      }
      Spacer()
      Menu {
        Button("Find Lyrics Online…", systemImage: "magnifyingglass") { downloadTrack = track }
        Button(status == .none ? "Write & Sync…" : "Edit & Sync…", systemImage: "metronome") { editTrack = track }
        Button("Play", systemImage: "play") { player.play(albumID: album.id, startAt: track.id) }
      } label: {
        Image(systemName: "ellipsis.circle").font(.title3).frame(width: 40, height: 40)
      }.accessibilityLabel("Lyrics actions for \(track.title)")
    }
    .contentShape(Rectangle())
    .onTapGesture { status == .none ? (downloadTrack = track) : (editTrack = track) }
  }

  private func fetch(_ scope: LyricsFetchScope) {
    store.fetch(scope, tracks: allTracks) { id in
      if lyrics.trackID == id, let track = library.track(id) { Task { await lyrics.load(track: track) } }
    }
  }

  private func export(plain: Bool) {
    preparingExport = true
    let tracks = allTracks
    let directory = store.directory
    Task {
      let files = await Task.detached(priority: .userInitiated) {
        MobileLyricsLibrary.exportFiles(tracks, plainText: plain, directory: directory)
      }.value
      preparingExport = false
      guard !files.isEmpty else {
        store.notice = "There are no lyrics to export yet."
        return
      }
      exportDocument = LyricsFolderDocument(files: files)
      exporting = true
    }
  }
}
