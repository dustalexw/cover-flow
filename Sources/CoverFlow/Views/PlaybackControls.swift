import SwiftUI

/// Play / previous / next with optional shuffle and repeat. Shared by the main bar and Album View.
struct TransportControls: View {
    var size: CGFloat = 34
    var showModes = true
    @EnvironmentObject private var player: PlayerEngine

    var body: some View {
        HStack(spacing: size * 0.32) {
            if showModes {
                Button { player.toggleShuffle() } label: { Image(systemName: "shuffle") }
                    .buttonStyle(IconButtonStyle(size: size * 0.82, active: player.shuffle))
                    .help(player.shuffle ? "Shuffle is on" : "Shuffle is off")
                    .accessibilityLabel("Shuffle")
                    .accessibilityValue(player.shuffle ? "On" : "Off")
            }
            Button { player.previous() } label: { Image(systemName: "backward.fill") }
                .buttonStyle(IconButtonStyle(size: size))
                .disabled(!player.hasTrack)
                .help("Previous track")
                .accessibilityLabel("Previous track")
            Button { player.togglePlayPause() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .offset(x: player.isPlaying ? 0 : size * 0.03)
            }
            .buttonStyle(IconButtonStyle(size: size * 1.25, prominent: true))
            .disabled(!player.hasTrack)
            .help(player.isPlaying ? "Pause" : "Play")
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            Button { player.next() } label: { Image(systemName: "forward.fill") }
                .buttonStyle(IconButtonStyle(size: size))
                .disabled(!player.hasTrack)
                .help("Next track")
                .accessibilityLabel("Next track")
            if showModes {
                Button { player.cycleRepeat() } label: {
                    Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                }
                .buttonStyle(IconButtonStyle(size: size * 0.82, active: player.repeatMode != .off))
                .help(player.repeatMode.label)
                .accessibilityLabel("Repeat")
                .accessibilityValue(player.repeatMode == .off ? "Off" : (player.repeatMode == .all ? "All" : "One"))
            }
        }
    }
}

/// Elapsed / scrubber / remaining. Holds its own value while dragging so playback updates don't fight the hand.
struct SeekBar: View {
    var compact = false
    @EnvironmentObject private var player: PlayerEngine
    @Environment(\.colorScheme) private var scheme
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0

    var body: some View {
        let shown = scrubbing ? scrubValue : player.currentTime
        HStack(spacing: 8) {
            Text(formatTime(shown))
                .font(.system(size: compact ? 10 : 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)
            Slider(value: Binding(get: { scrubbing ? scrubValue : min(player.currentTime, max(player.duration, 0.01)) },
                                  set: { v in
                                      if scrubbing { scrubValue = v } else { player.seek(to: v) }
                                  }),
                   in: 0...max(player.duration, 0.01),
                   onEditingChanged: { editing in
                       if editing {
                           scrubValue = player.currentTime
                           scrubbing = true
                       } else {
                           player.seek(to: scrubValue)
                           scrubbing = false
                       }
                   })
                .controlSize(.mini)
                .tint(Palette.accent(scheme))
                .disabled(!player.hasTrack)
                .accessibilityLabel("Playback position")
                .accessibilityValue("\(formatTime(shown)) of \(formatTime(player.duration))")
            Text("-" + formatTime(max(0, player.duration - shown)))
                .font(.system(size: compact ? 10 : 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .leading)
        }
    }
}

struct VolumeControl: View {
    var showSlider = true
    @EnvironmentObject private var player: PlayerEngine
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 6) {
            Button { player.toggleMute() } label: { Image(systemName: icon) }
                .buttonStyle(IconButtonStyle(size: 28, active: player.isMuted))
                .help(player.isMuted ? "Unmute" : "Mute")
                .accessibilityLabel(player.isMuted ? "Unmute" : "Mute")
            if showSlider {
                Slider(value: $player.volume, in: 0...1)
                    .controlSize(.mini)
                    .tint(Palette.accent(scheme))
                    .frame(width: 92)
                    .opacity(player.isMuted ? 0.45 : 1)
                    .accessibilityLabel("Volume")
                    .accessibilityValue("\(Int(player.volume * 100)) percent\(player.isMuted ? ", muted" : "")")
            }
        }
    }

    private var icon: String {
        if player.isMuted || player.volume == 0 { return "speaker.slash.fill" }
        if player.volume < 0.34 { return "speaker.wave.1.fill" }
        if player.volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}

/// The persistent player strip at the bottom of the main window.
struct NowPlayingBar: View {
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var albumView: AlbumViewController
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width > 1040
            let medium = geo.size.width > 860
            HStack(spacing: 16) {
                // Now playing
                HStack(spacing: 12) {
                    Button { albumView.toggle() } label: {
                        ArtworkView(album: player.currentAlbum, pointSize: 52, cornerRadius: 3)
                            .frame(width: 52, height: 52)
                            .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                    }
                    .buttonStyle(.plain)
                    .disabled(!player.hasTrack && !albumView.isOpen)
                    .help("Open Album View")
                    .accessibilityLabel("Open Album View")
                    VStack(alignment: .leading, spacing: 2) {
                        if let track = player.currentTrack {
                            ScrollingTrackTitle(track.title)
                                .font(.system(size: 13, weight: .semibold))
                            Button {
                                state.reveal(player.currentAlbumID)
                            } label: {
                                Text("\(track.artist) — \(player.currentAlbum?.title ?? track.albumTitle)")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .buttonStyle(.plain)
                            .help("Show this album (⌘L)")
                        } else {
                            Text("Nothing playing")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.secondary)
                            Text("Choose an album and press Play")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .frame(width: wide ? 280 : (medium ? 210 : 150), alignment: .leading)

                Spacer(minLength: 0)

                VStack(spacing: 4) {
                    TransportControls(size: 30, showModes: medium)
                    SeekBar()
                        .frame(maxWidth: 520)
                }
                .frame(maxWidth: 560)

                Spacer(minLength: 0)

                HStack(spacing: 6) {
                    VolumeControl(showSlider: wide)
                    Button { AppEnvironment.shared.lyricsWindow.show() } label: { Image(systemName: "text.quote") }
                        .buttonStyle(IconButtonStyle(size: 28))
                        .help("Open Lyrics (⌘4)").accessibilityLabel("Lyrics")
                    KaraokePlaybackButtons()
                    Button { state.showQueue.toggle() } label: { Image(systemName: "list.bullet") }
                        .buttonStyle(IconButtonStyle(size: 28, active: state.showQueue))
                        .help(state.showQueue ? "Hide queue (⌘U)" : "Show queue (⌘U)")
                        .accessibilityLabel(state.showQueue ? "Hide queue" : "Show queue")
                    Button { albumView.toggle() } label: {
                        Label("Album View", systemImage: albumView.isOpen ? "rectangle.inset.filled" : "photo")
                            .labelStyle(AlbumViewLabelStyle(showTitle: medium))
                    }
                    .buttonStyle(PillButtonStyle(prominent: albumView.isOpen))
                    .help("Album View — a resizable player for the current cover (⇧⌘A)")
                    .accessibilityLabel(albumView.isOpen ? "Close Album View" : "Open Album View")
                }
                .frame(width: wide ? 426 : (medium ? 336 : 246), alignment: .trailing)
            }
            .padding(.horizontal, 18)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(height: 80)
        .background(Palette.bar(scheme))
        .overlay(alignment: .top) { Rectangle().fill(Palette.hairline(scheme)).frame(height: 1) }
    }
}

struct AlbumViewLabelStyle: LabelStyle {
    var showTitle: Bool
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
            if showTitle { configuration.title }
        }
    }
}
