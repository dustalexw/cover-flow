import SwiftUI

struct MobilePlaybackBar: View {
  /// The window's fold. In book posture the track information sits on the left page
  /// and every control on the right page, so nothing straddles the fold.
  var fold: FoldGeometry = .flat
  @EnvironmentObject private var library: LibraryStore
  @EnvironmentObject private var app: MobileEnvironment
  @EnvironmentObject private var player: PlayerEngine
  @EnvironmentObject private var karaoke: MobileKaraokeStore
  var body: some View {
    VStack(spacing: 6) {
      Divider()
      if fold.posture == .book, fold.paneGap > 0 {
        HStack(spacing: 0) {
          information.padding(.horizontal, 18)
            .frame(width: CGFloat(fold.leadingPaneWidth()), alignment: .leading)
          Color.clear.frame(width: CGFloat(fold.paneGap)).accessibilityHidden(true)
          ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
              transport
              Spacer(minLength: 4)
              sourceButtons
              RoutePicker().frame(width: 40, height: 40)
              moreButton
            }
            HStack(spacing: 8) {
              transport
              Spacer(minLength: 4)
              moreButton
            }
          }.padding(.horizontal, 12).frame(maxWidth: .infinity)
        }.padding(.vertical, 8)
      } else {
        flatLayout
      }
      if karaoke.processing {
        Button {
          app.tab = .karaoke
        } label: {
          HStack {
            ProgressView(value: karaoke.progress).frame(maxWidth: 250)
            Text(
              "\(Int(karaoke.progress*100))% · \(karaoke.cancelling ? "Cancelling" : "Preparing karaoke")"
            ).font(.caption)
          }
        }.buttonStyle(.plain).padding(.bottom, 8)
      }
    }.background(.bar)
  }
  private var moreButton: some View {
    Button {
      app.nowPlaying = true
    } label: {
      Image(systemName: "ellipsis.circle").font(.title2).frame(width: 44, height: 44)
    }.accessibilityLabel("Open Album View")
  }
  private var flatLayout: some View {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 18) {
          information.frame(minWidth: 140, maxWidth: .infinity)
          transport
          Divider().frame(height: 28)
          sourceButtons
          Button {
            app.tab = .lyrics
          } label: {
            Image(systemName: "quote.bubble").frame(width: 40, height: 44)
          }.accessibilityLabel("Lyrics")
          RoutePicker().frame(width: 40, height: 40)
          Button {
            app.tab = .queue
          } label: {
            Image(systemName: "list.bullet").frame(width: 40, height: 44)
          }.accessibilityLabel("Up Next")
        }
        HStack(spacing: 10) {
          information
          Spacer()
          Button {
            player.togglePlayPause()
          } label: {
            Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title2).frame(
              width: 44, height: 44)
          }.disabled(!player.hasTrack).accessibilityLabel(player.isPlaying ? "Pause" : "Play")
          Button {
            app.nowPlaying = true
          } label: {
            Image(systemName: "ellipsis.circle").font(.title2).frame(width: 44, height: 44)
          }.accessibilityLabel("Open Now Playing")
        }
      }.padding(.horizontal, 18).padding(.vertical, 8)
  }
  private var information: some View {
    Button {
      app.nowPlaying = true
    } label: {
      HStack(spacing: 12) {
        if let album = library.album(player.currentAlbumID) {
          MobileArtwork(album: album, pixels: 180).frame(width: 48, height: 48)
        } else {
          Image(systemName: "music.note").frame(width: 48, height: 48).background(
            .quaternary, in: RoundedRectangle(cornerRadius: 10))
        }
        VStack(alignment: .leading, spacing: 4) {
          ScrollingTrackTitle(library.track(player.currentTrackID)?.title ?? "Choose a record")
            .font(
              .subheadline.weight(.semibold)
            )
            .lineLimit(2)
          Text(library.track(player.currentTrackID)?.artist ?? "Cover Flow for iOS").font(.caption)
            .foregroundStyle(
              .secondary
            ).lineLimit(1)
        }
      }.foregroundStyle(.primary)
    }.buttonStyle(.plain)
  }
  private var transport: some View {
    HStack(spacing: 6) {
      Button {
        player.previous()
      } label: {
        Image(systemName: "backward.end.fill").frame(width: 44, height: 44)
      }.accessibilityLabel("Previous track")
      Button {
        player.togglePlayPause()
      } label: {
        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title2).frame(
          width: 44, height: 44)
      }.accessibilityLabel(player.isPlaying ? "Pause" : "Play")
      Button {
        player.next()
      } label: {
        Image(systemName: "forward.end.fill").frame(width: 44, height: 44)
      }.accessibilityLabel("Next track")
    }.disabled(!player.hasTrack)
  }
  private var sourceButtons: some View {
    HStack(spacing: 4) {
      MobileSourceButton(mode: .instrumental)
      MobileSourceButton(mode: .vocals)
    }
  }
}
struct MobileSourceButton: View {
  let mode: KaraokePlayback
  @EnvironmentObject private var player: PlayerEngine
  @EnvironmentObject private var karaoke: MobileKaraokeStore
  @EnvironmentObject private var app: MobileEnvironment
  var body: some View {
    Button {
      guard let track = player.currentTrack else { return }
      if karaoke.selected == nil, karaoke.audio == nil {
        app.tab = .karaoke
        return
      }
      let requested = player.karaokePlayback == mode ? KaraokePlayback.original : mode
      let engine = player
      karaoke.request(requested, track: track) { [weak engine] mode, audio in
        guard let engine, engine.currentTrackID == track.id else { return }
        if engine.karaokePlayback != mode { engine.setKaraokePlayback(mode, audio: audio) }
      }
    } label: {
      Image(systemName: mode == .instrumental ? "mic.slash.fill" : "mic.fill").frame(
        width: 42, height: 44
      ).background(
        player.karaokePlayback == mode ? MobilePalette.brass.opacity(0.18) : .clear,
        in: RoundedRectangle(cornerRadius: 10))
    }
    .disabled(!player.hasTrack).accessibilityLabel(
      player.karaokePlayback == mode ? "No Karaoke — original audio" : mode.title
    ).accessibilityValue(player.karaokePlayback == mode ? "Selected" : "")
  }
}
struct MobileTransport: View {
  @EnvironmentObject private var player: PlayerEngine
  @State private var position = 0.0
  @State private var scrubbing = false
  var body: some View {
    VStack(spacing: 18) {
      VStack(spacing: 2) {
        Slider(
          value: $position, in: 0...max(1, player.duration),
          onEditingChanged: { value in
            scrubbing = value
            if !value { player.seek(to: position) }
          }
        ).accessibilityLabel("Playback position")
        HStack {
          Text(formatTime(position))
          Spacer()
          Text("−" + formatTime(max(0, player.duration - position)))
        }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
      }
      ViewThatFits(in: .horizontal) {
        controls(spacing: 26)
        controls(spacing: 4)
      }
    }.disabled(!player.hasTrack).onChange(of: player.currentTime, initial: true) { _, value in
      if !scrubbing { position = value }
    }.onChange(of: player.currentTrackID) { _, _ in
      scrubbing = false
      position = player.currentTime
    }
  }
  private func controls(spacing: CGFloat) -> some View {
    HStack(spacing: spacing) {
      Button {
        player.toggleShuffle()
      } label: {
        Image(systemName: "shuffle").foregroundStyle(
          player.shuffle ? MobilePalette.brass : .secondary
        ).frame(width: 44, height: 44)
      }.accessibilityLabel("Shuffle").accessibilityValue(
        player.shuffle ? "On" : "Off")
      Button {
        player.previous()
      } label: {
        Image(systemName: "backward.end.fill").font(.title2).frame(width: 44, height: 44)
      }.accessibilityLabel("Previous track")
      Button {
        player.togglePlayPause()
      } label: {
        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(
          .system(size: 64))
      }.frame(width: 64, height: 64).accessibilityLabel(player.isPlaying ? "Pause" : "Play")
      Button {
        player.next()
      } label: {
        Image(systemName: "forward.end.fill").font(.title2).frame(width: 44, height: 44)
      }.accessibilityLabel("Next track")
      Button {
        player.cycleRepeat()
      } label: {
        Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat").foregroundStyle(
          player.repeatMode == .off ? .secondary : MobilePalette.brass
        ).frame(width: 44, height: 44)
      }.accessibilityLabel(player.repeatMode.label)
    }.buttonStyle(.plain).frame(minHeight: 60)
  }

}
struct MobileQueueView: View {
  @EnvironmentObject private var player: PlayerEngine
  @EnvironmentObject private var library: LibraryStore
  var body: some View {
    List {
      if let track = player.currentTrack {
        Section("Now Playing") { MobileTrackRow(track: track, playing: player.isPlaying) }
      }
      Section("Up Next") {
        ForEach(player.upNext) { entry in
          if let track = library.track(entry.trackID) {
            Button {
              player.jump(toAbsolute: entry.id)
            } label: {
              MobileTrackRow(track: track)
            }
            .buttonStyle(.plain)
            .contextMenu {
              Button("Play Next") { player.move(absoluteIndex: entry.id, .top) }
              Button("Remove", role: .destructive) {
                player.removeFromQueue(absoluteIndex: entry.id)
              }
            }
          }
        }
        .onMove { player.moveUpNext(from: $0, to: $1) }
        .onDelete { offsets in
          for offset in offsets.sorted(by: >) {
            if let entry = player.upNext[safe: offset] {
              player.removeFromQueue(absoluteIndex: entry.id)
            }
          }
        }
        if player.upNext.isEmpty {
          Text("Add albums or tracks from the collection.").foregroundStyle(.secondary)
        }
      }
    }
    .toolbar {
      ToolbarItemGroup(placement: .topBarTrailing) {
        Button("Clear Upcoming") { player.clearUpNext() }.disabled(player.upNext.isEmpty)
        EditButton()
      }
    }
  }
}
