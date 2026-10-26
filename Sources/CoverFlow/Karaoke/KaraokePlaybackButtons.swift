import SwiftUI

/// Direct source controls beside Lyrics in the standard playback bar.
struct KaraokePlaybackButtons: View {
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var karaoke: KaraokeStore
    @Environment(\.colorScheme) private var scheme
    @State private var showDetails = false

    private var selected: KaraokePlayback { karaoke.requestedPlayback ?? player.karaokePlayback }

    var body: some View {
        VStack(spacing: 3) {
            VStack(spacing: 1) {
                HStack(spacing: 1) {
                modeButton(.instrumental, symbol: "mic.slash.fill", title: "Karaoke")
                modeButton(.vocals, symbol: "mic.fill", title: "Vocals Only")
                Button { AppEnvironment.shared.karaokeWindow.show() } label: {
                    Image(systemName: "slider.horizontal.3").frame(width: 28, height: 25)
                }.buttonStyle(.plain).help("Open Stem Mix").accessibilityLabel("Stem Mix")
                }
                HStack(spacing: 1) {
                    ForEach([AudioStem.drums, .bass, .guitar, .piano, .other]) { stem in
                        modeButton(KaraokePlayback(rawValue: stem.rawValue)!, symbol: stem.symbol, title: stem.title + " Only", compact: true)
                    }
                }
            }
            .padding(3)
            .background(Palette.raised(scheme), in: Capsule())
            .overlay { Capsule().strokeBorder(Palette.hairline(scheme), lineWidth: 1) }
            if karaoke.isProcessing {
                Button { showDetails = true } label: {
                    HStack(spacing: 3) {
                        ProgressView(value: karaoke.progress).progressViewStyle(.linear).tint(Palette.accent(scheme))
                        Text("\(Int(karaoke.progress * 100))%")
                            .font(.system(size: 9, weight: .medium, design: .monospaced)).monospacedDigit()
                    }
                }
                .buttonStyle(.plain).help("\(karaoke.stage) — click for preparation details")
                .accessibilityLabel("Karaoke preparation")
                .accessibilityValue("\(Int(karaoke.progress * 100)) percent. \(karaoke.stage)")
            } else if karaoke.errorMessage != nil {
                Button { showDetails = true } label: {
                    Label("Try again", systemImage: "exclamationmark.circle")
                        .font(.system(size: 9)).foregroundStyle(.orange)
                }.buttonStyle(.plain).help("Show karaoke preparation error")
            }
        }
        .frame(width: 126)
        .popover(isPresented: $showDetails, arrowEdge: .top) { details }
        .contextMenu {
            Button("Open Karaoke…") { AppEnvironment.shared.karaokeWindow.show() }
            if karaoke.isProcessing { Button("Cancel preparation") { karaoke.cancel() } }
        }
        .onChange(of: player.currentTrackID, initial: true) { karaoke.refresh(for: player.currentTrack) }
        .onChange(of: karaoke.errorMessage) { if karaoke.errorMessage != nil { showDetails = true } }
    }

    private func modeButton(_ mode: KaraokePlayback, symbol: String, title: String, compact: Bool = false) -> some View {
        let active = selected == mode
        return Button {
            guard let track = player.currentTrack else { return }
            karaoke.requestPlayback(active ? .original : mode, for: track) { [weak player = player] mode, audio in
                guard let player, player.currentTrackID == track.id else { return }
                if player.karaokePlayback != mode { player.setKaraokePlayback(mode, audio: audio) }
            }
        } label: {
            Image(systemName: symbol)
                .frame(width: compact ? 22 : 28, height: 24)
                .font(.system(size: compact ? 12 : 14, weight: .semibold))
                .foregroundStyle(active ? Palette.onAccent(scheme) : Color.secondary)
                .background(active ? Palette.accent(scheme) : Color.clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain).disabled(!player.hasTrack)
        .opacity(player.hasTrack ? 1 : 0.35)
        .help(active ? "\(title) selected — click for No Karaoke (original audio)"
                    : "\(title) — prepare automatically and switch playback")
        .accessibilityLabel(title)
        .accessibilityValue(active ? (karaoke.requestedPlayback == mode ? "Preparing" : "On") : "Off")
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Karaoke", systemImage: "music.mic").font(.headline)
            if karaoke.isProcessing {
                ScrollingTrackTitle("Preparing \(karaoke.processingTitle ?? "track")")
                Text(karaoke.stage).font(.caption).foregroundStyle(.secondary)
                ProgressView(value: karaoke.progress)
                Text(karaoke.requestedPlayback == nil ? "Original audio continues playing."
                     : "Switching to \(karaoke.requestedPlayback!.title) when ready.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Cancel preparation") { karaoke.cancel() }
            }
            if let error = karaoke.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            Button("Open Karaoke…") { showDetails = false; AppEnvironment.shared.karaokeWindow.show() }
        }.padding(18).frame(width: 280).tint(Palette.accent(scheme))
    }
}
