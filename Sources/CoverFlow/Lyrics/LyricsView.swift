import SwiftUI
import AppKit

struct LyricsView: View {
    var playbackActions: AnyView? = nil
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var state: AppState
    @StateObject private var lyrics = LyricsStore(directory: AppPaths.root.appendingPathComponent("Lyrics", isDirectory: true))
    @State private var followPlayback = true
    @State private var downloadTrack: Track?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            header.padding(20)
            Divider()
            Group {
                if lyrics.loading {
                    ProgressView("Reading lyrics…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let loaded = lyrics.loaded {
                    if loaded.document.isSynced {
                        SyncedLyricsView(document: loaded.document, followPlayback: $followPlayback)
                            .id(lyrics.trackID)
                    } else {
                        ScrollView {
                            Text(loaded.document.plainText)
                                .font(.system(size: 22, weight: .medium))
                                .lineSpacing(12).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(28)
                        }
                    }
                } else {
                    VStack(spacing: 14) {
                        Image(systemName: "text.quote").font(.system(size: 36)).foregroundStyle(.secondary)
                        Text(player.hasTrack ? "No lyrics for this track" : "Choose a track to see its lyrics")
                            .font(.system(size: 20, weight: .semibold))
                        Text(player.hasTrack
                             ? "Search for synced or plain lyrics, or import a lyric file from your Mac."
                             : "Lyrics follow the track playing in Cover Flow.")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).frame(maxWidth: 340)
                        if let track = player.currentTrack {
                            HStack {
                                Button("Find Lyrics…") { downloadTrack = track }.buttonStyle(.borderedProminent)
                                Button("Import Lyrics…") { lyrics.chooseFile(for: track) }
                            }
                        }
                    }
                    .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            if let error = lyrics.errorMessage {
                Text(error).font(.system(size: 12)).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.bottom, 12)
            }
            Divider()
            VStack(spacing: 10) {
                HStack {
                    if lyrics.loaded?.document.isSynced == true {
                        Toggle("Follow playback", isOn: $followPlayback).toggleStyle(.checkbox).font(.system(size: 12))
                    } else {
                        Text(lyrics.loaded == nil ? "LRC and plain lyrics" : "Untimed lyrics")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if playbackActions == nil {
                        TransportControls(size: 26, showModes: false)
                    } else {
                        Text("Space: pause / resume").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                if let playbackActions {
                    HStack(spacing: 12) {
                        playbackActions
                        Spacer(minLength: 0)
                        TransportControls(size: 26, showModes: false)
                    }
                }
                SeekBar(compact: true)
            }.padding(16)
        }
        .background(Palette.base(scheme))
        .tint(Palette.accent(scheme))
        .preferredColorScheme(state.colorScheme)
        .task(id: player.currentTrackID) { await lyrics.load(track: player.currentTrack) }
        .sheet(item: $downloadTrack) { track in
            LyricsDownloadView(track: track) { match in
                guard library.track(track.id) != nil else { throw MusicLookupError.itemRemoved }
                try await lyrics.importDownloaded(match.text, for: track)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ArtworkView(album: player.currentAlbum, pointSize: 54, cornerRadius: 4).frame(width: 54, height: 54)
            VStack(alignment: .leading, spacing: 4) {
                ScrollingTrackTitle(player.currentTrack?.title ?? "Lyrics").font(.system(size: 18, weight: .semibold))
                Text(player.currentTrack?.artist ?? "Cover Flow").font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                if let loaded = lyrics.loaded {
                    Text(loaded.imported ? "Saved lyrics" : loaded.source.lastPathComponent)
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        .help(loaded.source.path)
                }
            }
            Spacer(minLength: 8)
            Button { Task { await lyrics.load(track: player.currentTrack) } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain).help("Reload lyrics from disk").accessibilityLabel("Reload lyrics")
                .disabled(!player.hasTrack || lyrics.loading)
            Menu {
                Button("Find Lyrics Online…") { downloadTrack = player.currentTrack }
                Button("Import LRC or Text…") { if let track = player.currentTrack { lyrics.chooseFile(for: track) } }
            } label: { Label("Add Lyrics", systemImage: "plus") }.disabled(!player.hasTrack).controlSize(.small)

        }
    }
}

private struct SyncedLyricsView: View {
    let document: LyricsDocument
    @Binding var followPlayback: Bool
    @EnvironmentObject private var player: PlayerEngine
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var active: Int? { document.activeIndex(at: player.currentTime) }

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    ForEach(document.cues) { cue in
                        Button { player.seek(to: document.playbackTime(for: cue)) } label: {
                            Text(cue.text.isEmpty ? "♪" : cue.text)
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(active == cue.id ? Palette.accent(scheme) : Color.secondary)
                                .lineSpacing(6).multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).id(cue.id)
                        .help("Jump to \(formatTime(document.playbackTime(for: cue)))")
                        .accessibilityLabel(cue.text.isEmpty ? "Instrumental break" : cue.text)
                        .accessibilityValue(active == cue.id ? "Current lyric" : "")
                    }
                }.padding(.horizontal, 28).padding(.vertical, 90)
            }
            .onChange(of: active, initial: true) { follow(reader) }
            .onChange(of: followPlayback) { follow(reader) }
        }
    }

    private func follow(_ reader: ScrollViewProxy) {
        guard followPlayback, let active else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
            reader.scrollTo(active, anchor: .center)
        }
    }
}
