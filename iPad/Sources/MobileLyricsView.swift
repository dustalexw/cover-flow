import SwiftUI
import UniformTypeIdentifiers

struct MobileLyricsView: View {
  @EnvironmentObject private var library: LibraryStore
  @EnvironmentObject private var player: PlayerEngine
  @EnvironmentObject private var lyrics: LyricsStore
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var follow = true
  @State private var importing = false
  @State private var importTrack: Track?
  @State private var downloadTrack: Track?
  @State private var editTrack: Track?
  @State private var showLibrary = false
  @State private var confirmDelete = false
  @EnvironmentObject private var lyricsLibrary: MobileLyricsLibrary
  var active: Int? { lyrics.loaded?.document.activeIndex(at: player.currentTime) }
  var body: some View {
    VStack(spacing: 0) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 4) {
          Text(library.track(player.currentTrackID)?.title ?? "Lyrics").font(
            .title3.weight(.semibold)
          ).fixedSize(
            horizontal: false, vertical: true)
          Text(library.track(player.currentTrackID)?.artist ?? "Choose a track first")
            .foregroundStyle(.secondary)
            .font(.subheadline)
        }
        Spacer()
        Menu {
          Button("Edit & Sync Lyrics…", systemImage: "metronome") { editTrack = player.currentTrack }
            .disabled(!player.hasTrack)
          Button("Find Lyrics Online…", systemImage: "magnifyingglass") { downloadTrack = player.currentTrack }
            .disabled(!player.hasTrack)
          Button("Import Lyrics…", systemImage: "doc") {
            importTrack = player.currentTrack
            importing = true
          }.disabled(!player.hasTrack)
          if let track = player.currentTrack, let loaded = lyrics.loaded {
            ShareLink(
              item: shareText(loaded),
              preview: SharePreview(
                MobileLyricsLibrary.fileName(for: track, ext: loaded.document.isSynced ? "lrc" : "txt"))
            ) {
              Label("Share Lyrics", systemImage: "square.and.arrow.up")
            }
          }
          Button("Reload Lyrics", systemImage: "arrow.clockwise") { Task { await lyrics.load(track: player.currentTrack) } }
            .disabled(!player.hasTrack)
          if lyrics.loaded?.imported == true {
            Button("Delete Lyrics", systemImage: "trash", role: .destructive) { confirmDelete = true }
          }
          Divider()
          Button("Lyrics Library…", systemImage: "books.vertical") { showLibrary = true }
        } label: {
          Image(systemName: "ellipsis.circle").font(.title2).frame(width: 44, height: 44)
        }.accessibilityLabel("Lyrics actions")
      }.padding(20)
      if lyrics.loaded?.document.isSynced == true {
        Toggle("Follow playback", isOn: $follow).font(.caption).padding(.horizontal, 20).padding(
          .bottom, 12)
      }
      Divider()
      if lyrics.loading {
        ProgressView().frame(maxHeight: .infinity)
      } else if let loaded = lyrics.loaded {
        if loaded.document.isSynced {
          ScrollViewReader { reader in
            ScrollView {
              LazyVStack(alignment: .leading, spacing: 22) {
                ForEach(loaded.document.cues) { cue in
                  Button {
                    player.seek(to: loaded.document.playbackTime(for: cue))
                  } label: {
                    lineText(cue, document: loaded.document, isActive: active == cue.id)
                      .font(
                        .system(
                          size: active == cue.id ? 28 : 24,
                          weight: active == cue.id ? .semibold : .regular)
                      ).fixedSize(
                        horizontal: false, vertical: true
                      ).frame(maxWidth: .infinity, alignment: .leading)
                  }.buttonStyle(.plain).id(cue.id).accessibilityLabel(
                    cue.text.isEmpty ? "Instrumental" : cue.text
                  ).accessibilityHint(
                    "Seek to \(formatTime(loaded.document.playbackTime(for:cue)))")
                }
              }.padding(28).padding(.bottom, 100)
            }
            .onChange(of: active, initial: true) { _, value in
              if follow, let value {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.28)) {
                  reader.scrollTo(value, anchor: .center)
                }
              }
            }
            .onChange(of: follow) { _, value in
              if value, let active { reader.scrollTo(active, anchor: .center) }
            }
          }
        } else {
          ScrollView {
            Text(loaded.document.plainText).font(.title3).textSelection(.enabled).frame(
              maxWidth: .infinity, alignment: .leading
            ).padding(28)
          }
        }
      } else {
        ContentUnavailableView {
          Label("Lyrics for your music", systemImage: "quote.bubble")
        } description: {
          Text(
            lyrics.errorMessage
              ?? "Import a timed .lrc file or a music folder containing matching lyric sidecars. Tap a timed line to seek."
          )
        } actions: {
          Button("Find Lyrics Online…") { downloadTrack = player.currentTrack }
            .buttonStyle(.borderedProminent).disabled(!player.hasTrack)
          Button("Write & Sync Lyrics…") { editTrack = player.currentTrack }.disabled(!player.hasTrack)
          Button("Import LRC…") {
            importTrack = player.currentTrack
            importing = true
          }.disabled(!player.hasTrack)
          Button("Lyrics Library…") { showLibrary = true }
        }
      }
    }
    .task(id: player.currentTrackID) { await lyrics.load(track: player.currentTrack) }
    .sheet(item: $downloadTrack) { track in
      LyricsDownloadView(track: track) { match in
        guard library.track(track.id) != nil else { throw MusicLookupError.itemRemoved }
        try await lyrics.importDownloaded(match.text, for: track)
        lyricsLibrary.update(track.id, audio: track.fileURL)
      }
    }
    .sheet(item: $editTrack) { track in
      MobileLyricsEditor(track: track) { lyricsLibrary.update(track.id, audio: track.fileURL) }
    }
    .sheet(isPresented: $showLibrary) { MobileLyricsLibraryView() }
    .confirmationDialog("Delete the lyrics saved for this track?", isPresented: $confirmDelete, titleVisibility: .visible) {
      Button("Delete Lyrics", role: .destructive) {
        guard let track = player.currentTrack, let loaded = lyrics.loaded, loaded.imported else { return }
        try? FileManager.default.removeItem(at: loaded.source)
        lyricsLibrary.update(track.id, audio: track.fileURL)
        Task { await lyrics.load(track: track) }
      }
    }
    .fileImporter(
      isPresented: $importing,
      allowedContentTypes: ["lrc", "txt", "lyric", "lyrics"].compactMap { UTType(filenameExtension: $0) } + [.plainText]
    ) { result in
      guard case .success(let url) = result, let track = importTrack else {
        if case .failure(let error) = result { lyrics.errorMessage = error.localizedDescription }
        return
      }
      Task {
        do {
          let directory = AppPaths.root.appendingPathComponent("Lyrics")
          _ = try await Task.detached(priority: .userInitiated) {
            try LyricsStore.importFile(url, trackID: track.id, directory: directory)
          }.value
          if player.currentTrackID == track.id { await lyrics.load(track: track) }
          lyricsLibrary.update(track.id, audio: track.fileURL)
        } catch { lyrics.errorMessage = error.localizedDescription }
      }
    }
  }

  /// A line, with the word being sung picked out when the line has word timings
  /// (enhanced LRC, as Lyripass writes).
  private func lineText(_ cue: LyricCue, document: LyricsDocument, isActive: Bool) -> Text {
    guard !cue.text.isEmpty else { return Text("♪").foregroundStyle(isActive ? Color.primary : Color.secondary) }
    guard isActive, !cue.words.isEmpty else {
      return Text(cue.text).foregroundStyle(isActive ? Color.primary : Color.secondary)
    }
    let current = document.activeWord(in: cue, at: player.currentTime)
    return cue.words.enumerated().reduce(Text("")) { result, item in
      let sung = current.map { item.offset <= $0 } ?? false
      return result + Text(item.element.text).foregroundStyle(sung ? MobilePalette.brass : Color.primary.opacity(0.55))
    }
  }

  private func shareText(_ loaded: LoadedLyrics) -> String {
    (try? String(contentsOf: loaded.source, encoding: .utf8)) ?? loaded.document.plainText
  }
}
