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
          Button("Import LRC…") {
            importTrack = player.currentTrack
            importing = true
          }.disabled(!player.hasTrack)
          Button("Reload Lyrics") { Task { await lyrics.load(track: player.currentTrack) } }
            .disabled(!player.hasTrack)
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
                    Text(cue.text.isEmpty ? "♪" : cue.text).font(
                      .system(
                        size: active == cue.id ? 28 : 24,
                        weight: active == cue.id ? .semibold : .regular)
                    ).foregroundStyle(active == cue.id ? Color.primary : Color.secondary).fixedSize(
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
          Button("Import LRC…") {
            importTrack = player.currentTrack
            importing = true
          }.disabled(!player.hasTrack)
        }
      }
    }
    .task(id: player.currentTrackID) { await lyrics.load(track: player.currentTrack) }
    .fileImporter(
      isPresented: $importing,
      allowedContentTypes: [UTType(filenameExtension: "lrc") ?? .plainText, .plainText]
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
        } catch { lyrics.errorMessage = error.localizedDescription }
      }
    }
  }
}
