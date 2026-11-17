import SwiftUI

// Album View on iOS, matching the Mac's three sizes: Compact is the playback bar,
// Large is the Now Playing sheet, and Immersive fills the display. On iPhone Duo's
// inner display Large and the tabletop player follow the fold.

/// Large Album View, presented as a sheet.
struct MobileNowPlayingView: View {
  @EnvironmentObject private var library: LibraryStore
  @EnvironmentObject private var player: PlayerEngine
  @EnvironmentObject private var app: MobileEnvironment
  @Environment(\.dismiss) private var dismiss
  @State private var artworkFocus = false
  var body: some View {
    NavigationStack {
      FoldReader { fold in
        MobileAlbumViewContent(fold: fold, artworkFocus: artworkFocus) { dismiss() }
      }
      .background {
        if let album = library.album(player.currentAlbumID) {
          MobileAlbumScene(album: album)
        } else {
          Color(uiColor: .systemBackground)
        }
      }
      .navigationTitle("Album View").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
        ToolbarItemGroup(placement: .topBarTrailing) {
          Button {
            artworkFocus.toggle()
          } label: {
            Image(systemName: artworkFocus ? "rectangle.compress.vertical" : "photo")
          }.accessibilityLabel("Artwork focus").keyboardShortcut("f", modifiers: [])
          Button {
            dismiss()
            app.immersive = true
          } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
          }.accessibilityLabel("Immersive Album View")
        }
      }
    }
  }
}

/// Artwork and controls arranged for the space and the fold.
struct MobileAlbumViewContent: View {
  let fold: FoldGeometry
  var artworkFocus = false
  /// Called before navigating elsewhere (Lyrics, Up Next, Karaoke).
  var leave: () -> Void = {}
  @EnvironmentObject private var library: LibraryStore
  @EnvironmentObject private var player: PlayerEngine
  var body: some View {
    let width = CGFloat(fold.size.width)
    let height = CGFloat(fold.size.height)
    if fold.posture == .book, fold.paneGap > 0 {
      // Book: artwork on the left page, everything you touch on the right page.
      let leading = CGFloat(fold.leadingPaneWidth())
      HStack(spacing: 0) {
        art.padding(28).frame(width: leading, height: height)
        Color.clear.frame(width: CGFloat(fold.paneGap)).accessibilityHidden(true)
        if !artworkFocus {
          ScrollView { MobileAlbumViewDetails(leave: leave).padding(24) }
            .frame(maxWidth: .infinity)
        } else {
          Spacer()
        }
      }
    } else if let upper = fold.tabletopUpperHeight {
      // Tabletop: viewing half above the fold, controls below it.
      VStack(spacing: 0) {
        MobileTabletopHeader(showsLyrics: !artworkFocus).frame(height: CGFloat(upper))
        Color.clear.frame(height: CGFloat(fold.division?.height ?? 0)).accessibilityHidden(true)
        ScrollView {
          MobileAlbumViewDetails(showsTitles: false, leave: leave).padding(.horizontal, 32)
            .padding(.vertical, 16).frame(maxWidth: 640)
        }.frame(maxWidth: .infinity)
      }
    } else {
      ScrollView {
        if width > 780 {
          HStack(alignment: .top, spacing: 24) {
            art.frame(width: min(width * 0.44, max(140, height - 48), 580))
            if !artworkFocus { MobileAlbumViewDetails(leave: leave).frame(maxWidth: 440) }
          }.frame(maxWidth: .infinity, minHeight: height).padding(32)
        } else {
          VStack(spacing: 28) {
            // Short displays (iPhone Duo's outer display) keep the transport on screen.
            art.frame(maxWidth: artworkFocus ? 640 : min(480, max(160, height - 380)))
            if !artworkFocus { MobileAlbumViewDetails(leave: leave).frame(maxWidth: 480) }
          }.padding(20).frame(maxWidth: .infinity)
        }
      }
    }
  }
  @ViewBuilder private var art: some View {
    if let album = library.album(player.currentAlbumID) {
      MobileArtwork(album: album, pixels: 1800).shadow(radius: 24)
    } else {
      Image(systemName: "opticaldisc").font(.system(size: 160)).foregroundStyle(.secondary).frame(
        height: 300)
    }
  }
}

/// Titles, transport, volume, karaoke/stem sources and destinations.
struct MobileAlbumViewDetails: View {
  var showsTitles = true
  var leave: () -> Void = {}
  @EnvironmentObject private var library: LibraryStore
  @EnvironmentObject private var player: PlayerEngine
  @EnvironmentObject private var app: MobileEnvironment
  @EnvironmentObject private var karaoke: MobileKaraokeStore
  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      if showsTitles {
        VStack(alignment: .leading, spacing: 7) {
          Text(library.track(player.currentTrackID)?.title ?? "Nothing playing").font(
            .system(.title, design: .serif).weight(.semibold)
          ).fixedSize(horizontal: false, vertical: true)
          Text(library.track(player.currentTrackID)?.artist ?? "Select an album to begin").font(
            .title3
          )
          .foregroundStyle(.secondary)
          if let album = library.album(player.currentAlbumID) {
            Text(album.title).font(.subheadline).foregroundStyle(.secondary)
          }
        }
      }
      MobileTransport()
      HStack(spacing: 12) {
        Button {
          player.toggleMute()
        } label: {
          Image(systemName: player.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill").frame(
            width: 44, height: 44)
        }.accessibilityLabel(player.isMuted ? "Unmute" : "Mute")
        Slider(
          value: Binding(get: { player.volume }, set: { player.volume = $0 }), in: 0...1
        ).accessibilityLabel("Player volume")
      }
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 12) {
          sources
          Spacer()
          destinations
        }
        VStack(alignment: .leading, spacing: 12) {
          HStack {
            sources
            Spacer()
          }
          HStack {
            destinations
            Spacer()
          }
        }
      }
      MobileStemButtons()
      if karaoke.processing {
        VStack(alignment: .leading, spacing: 6) {
          ProgressView(value: karaoke.progress)
          Text(karaoke.stage).font(.caption).foregroundStyle(.secondary)
          Button("Preparation details") {
            app.tab = .karaoke
            leave()
          }
        }
      }
    }
  }
  private var sources: some View {
    HStack(spacing: 12) {
      MobileSourceButton(mode: .instrumental)
      MobileSourceButton(mode: .vocals)
    }
  }
  private var destinations: some View {
    HStack(spacing: 12) {
      Button {
        app.tab = .lyrics
        leave()
      } label: {
        Image(systemName: "quote.bubble").frame(width: 44, height: 44)
      }.accessibilityLabel("Lyrics")
      RoutePicker().frame(width: 44, height: 44)
      Button {
        app.tab = .queue
        leave()
      } label: {
        Image(systemName: "list.bullet").frame(width: 44, height: 44)
      }.accessibilityLabel("Up Next")
    }
  }
}

/// The upper (viewing) half of the tabletop player: artwork, titles and the current
/// lyric lines, readable from across a table.
struct MobileTabletopHeader: View {
  var showsLyrics = true
  @EnvironmentObject private var library: LibraryStore
  @EnvironmentObject private var player: PlayerEngine
  @EnvironmentObject private var lyrics: LyricsStore
  var body: some View {
    GeometryReader { size in
      HStack(alignment: .center, spacing: 28) {
        if let album = library.album(player.currentAlbumID) {
          MobileArtwork(album: album, pixels: 1200).shadow(radius: 18)
            .frame(width: max(80, min(size.size.height - 32, size.size.width * 0.45)))
        }
        VStack(alignment: .leading, spacing: 10) {
          Text(library.track(player.currentTrackID)?.title ?? "Nothing playing")
            .font(.system(.title, design: .serif).weight(.semibold)).lineLimit(2)
          Text(library.track(player.currentTrackID)?.artist ?? "Choose a record")
            .font(.title3).foregroundStyle(.secondary).lineLimit(1)
          if showsLyrics, let document = lyrics.loaded?.document, document.isSynced,
            lyrics.trackID == player.currentTrackID
          {
            let active = document.activeIndex(at: player.currentTime)
            let cues = document.cues
            if let active, let position = cues.firstIndex(where: { $0.id == active }) {
              VStack(alignment: .leading, spacing: 6) {
                Text(cues[position].text.isEmpty ? "♪" : cues[position].text)
                  .font(.title2.weight(.semibold)).lineLimit(2)
                if position + 1 < cues.count {
                  Text(cues[position + 1].text).font(.title3).foregroundStyle(.secondary)
                    .lineLimit(1)
                }
              }.padding(.top, 8).accessibilityElement(children: .combine)
            }
          }
        }.frame(maxWidth: .infinity, alignment: .leading)
      }.padding(.horizontal, 32).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .task(id: player.currentTrackID) {
      if lyrics.trackID != player.currentTrackID { await lyrics.load(track: player.currentTrack) }
    }
  }
}

/// iPhone Duo standing in tabletop posture: Album View with the fold between the
/// artwork and the controls. Browse returns to the collection until the pose changes.
struct MobileTabletopPlayer: View {
  let fold: FoldGeometry
  let browse: () -> Void
  @EnvironmentObject private var library: LibraryStore
  @EnvironmentObject private var player: PlayerEngine
  @EnvironmentObject private var app: MobileEnvironment
  var body: some View {
    MobileAlbumViewContent(fold: fold) { browse() }
      .overlay(alignment: .bottomTrailing) {
        Button {
          browse()
        } label: {
          Label("Browse", systemImage: "square.stack.fill").padding(.horizontal, 6)
        }.buttonStyle(.bordered).padding(20)
      }
      .background {
        if let album = library.album(player.currentAlbumID) {
          MobileAlbumScene(album: album)
        } else {
          Color(uiColor: .systemBackground).ignoresSafeArea()
        }
      }
  }
}

/// Immersive Album View: the cover fills the display over its extended scene.
/// Tap to show or hide the controls. Escape closes; F toggles artwork focus.
struct MobileImmersiveAlbumView: View {
  @EnvironmentObject private var library: LibraryStore
  @EnvironmentObject private var player: PlayerEngine
  @Environment(\.dismiss) private var dismiss
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var controls = true
  @State private var focusArtwork = false
  @State private var lastInteraction = Date()
  @FocusState private var focused: Bool
  var body: some View {
    FoldReader { fold in
      ZStack {
        if let album = library.album(player.currentAlbumID) {
          let cover = coverFrame(album, fold: fold)
          MobileImmersiveScene(
            album: album, viewport: CGSize(width: fold.size.width, height: fold.size.height),
            cover: cover)
          // The artwork view letterboxes inside a square; `cover` is the image within it.
          MobileArtwork(album: album, pixels: 2400)
            .frame(width: max(cover.width, cover.height), height: max(cover.width, cover.height))
            .shadow(color: .black.opacity(0.5), radius: 40, y: 20)
            .position(x: cover.midX, y: cover.midY)
            .animation(reduceMotion ? nil : .spring(duration: 0.4), value: focusArtwork)
        } else {
          Color.black.ignoresSafeArea()
          Image(systemName: "opticaldisc").font(.system(size: 120)).foregroundStyle(.secondary)
        }
      }
      .contentShape(Rectangle())
      .onTapGesture { toggleControls() }
      .overlay(alignment: .bottom) {
        if controls && !focusArtwork {
          bottomControls(fold: fold).transition(.opacity)
        }
      }
      .overlay(alignment: .topLeading) {
        if controls {
          HStack {
            Button {
              dismiss()
            } label: {
              Image(systemName: "xmark").font(.title3.weight(.semibold)).frame(width: 44, height: 44)
            }.accessibilityLabel("Close Immersive Album View")
            Spacer()
            Button {
              focusArtwork.toggle()
            } label: {
              Image(systemName: focusArtwork ? "rectangle.compress.vertical" : "photo").frame(
                width: 44, height: 44)
            }.accessibilityLabel("Artwork focus")
          }.buttonStyle(.bordered).buttonBorderShape(.circle).padding(20).transition(.opacity)
        }
      }
    }
    .ignoresSafeArea()
    .statusBarHidden(!controls)
    .persistentSystemOverlays(controls ? .automatic : .hidden)
    .environment(\.colorScheme, .dark)
    .focusable().focused($focused).focusEffectDisabled()
    .onAppear { focused = true }
    .onKeyPress(.escape) {
      dismiss()
      return .handled
    }
    .onKeyPress(.space) {
      player.togglePlayPause()
      return .handled
    }
    .onKeyPress(.leftArrow) {
      player.previous()
      return .handled
    }
    .onKeyPress(.rightArrow) {
      player.next()
      return .handled
    }
    .onKeyPress(KeyEquivalent("f")) {
      focusArtwork.toggle()
      return .handled
    }
    .task {
      // Controls fade after a few quiet seconds, like the Mac's Immersive view.
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        if controls, player.isPlaying, Date().timeIntervalSince(lastInteraction) > 4 {
          withAnimation(reduceMotion ? nil : .easeOut(duration: 0.4)) { controls = false }
        }
      }
    }
  }
  private func toggleControls() {
    lastInteraction = Date()
    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { controls.toggle() }
  }
  /// Where the cover sits: centered, on the left page in book posture, or above
  /// the fold in tabletop posture. The extended scene is generated around this frame.
  private func coverFrame(_ album: Album, fold: FoldGeometry) -> CGRect {
    let width = CGFloat(fold.size.width)
    let height = CGFloat(fold.size.height)
    var side = min(width, height) * (focusArtwork ? 0.86 : 0.62)
    var center = CGPoint(x: width / 2, y: height / 2)
    if fold.posture == .book, fold.paneGap > 0 {
      let leading = CGFloat(fold.leadingPaneWidth())
      side = min(leading - 40, height * 0.8)
      center.x = leading / 2
    } else if let upper = fold.tabletopUpperHeight {
      side = min(CGFloat(upper) - 40, width * 0.5)
      center.y = CGFloat(upper) / 2
    }
    side = max(80, side)
    // The artwork view fits the image in a square; match the image's own shape.
    let aspect = max(0.2, min(5, album.artworkAspect))
    let size =
      aspect >= 1 ? CGSize(width: side, height: side / aspect) : CGSize(width: side * aspect, height: side)
    return CGRect(
      x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width,
      height: size.height)
  }
  private func bottomControls(fold: FoldGeometry) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(library.track(player.currentTrackID)?.title ?? "")
        .font(.system(.title2, design: .serif).weight(.semibold)).lineLimit(2)
      Text(library.track(player.currentTrackID)?.artist ?? "").foregroundStyle(.secondary)
      MobileTransport()
    }
    .padding(24).frame(maxWidth: 560)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
    .padding(.horizontal, 20).padding(.bottom, 28)
    // In book posture the controls belong on the right page.
    .frame(
      maxWidth: .infinity,
      alignment: fold.posture == .book && fold.paneGap > 0 ? .trailing : .center
    )
    .onTapGesture { lastInteraction = Date() }
  }
}
