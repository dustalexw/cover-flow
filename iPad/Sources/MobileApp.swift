import AVFoundation
import Combine
import SwiftUI

@MainActor final class MobileEnvironment: ObservableObject {
  let library: LibraryStore
  let scrobbler: LastFmScrobbler
  let player: PlayerEngine
  let lyrics: LyricsStore
  let karaoke: MobileKaraokeStore
  private var observers: [NSObjectProtocol] = []
  private var resumeAfterInterruption = false
  let artworkTags: MobileArtworkTagging
  let lyricsLibrary = MobileLyricsLibrary()
  @Published var tab: MobileTab = .library
  /// Album View: Large (sheet) and Immersive (full screen). Compact is the playback bar.
  @Published var nowPlaying = false
  @Published var immersive = false
  /// The album open in a sheet on compact displays.
  @Published var albumSheet: UUID?
  /// The album shown beside the browser on wide displays (iPhone Duo inner display, iPad).
  @Published var albumPanel: UUID?
  @Published var searchPresented = false
  /// Incremented to scroll the browser to the playing album (⌘L).
  @Published var revealPlaying = 0

  /// Shows the album in whichever way the current layout presents albums.
  func open(album id: UUID, expanded: Bool) {
    if expanded { albumPanel = id } else { albumSheet = id }
  }
  /// Moves an open album between the sheet and the side panel when the layout changes,
  /// so folding or unfolding iPhone Duo keeps what you were looking at.
  func layoutChanged(to layout: MobileLayoutClass) {
    switch layout {
    case .expanded:
      if tab == .more { tab = .settings }
    case .compact:
      // The panel stays remembered for the next unfold; nothing pops up on the small display.
      break
    }
  }
  init() {
    // Background playback needs the .playback category. The long-form policy
    // (music, podcasts) doesn't accept category options and throws if given any,
    // which used to leave the default category — audio that stops in the
    // background and on lock. AirPlay and Bluetooth are allowed by default.
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
    } catch {
      try? session.setCategory(.playback, mode: .default, options: [])
    }
    let library = LibraryStore()
    let scrobbler = LastFmScrobbler()
    self.library = library
    self.scrobbler = scrobbler
    library.load()
    player = PlayerEngine(library: library, scrobbler: scrobbler)
    lyrics = LyricsStore(directory: AppPaths.root.appendingPathComponent("Lyrics"))
    karaoke = MobileKaraokeStore(root: AppPaths.root.appendingPathComponent("Karaoke"))
    artworkTags = MobileArtworkTagging(library: library)
    let playerPurge = library.onTracksRemoved
    let karaoke = self.karaoke
    library.onTracksRemoved = { [weak karaoke] ids in
      playerPurge?(ids)
      MainActor.assumeIsolated { karaoke?.purge(ids) }
    }
    let engine = self.player
    library.onMetadataChanged = { [weak engine] in
      MainActor.assumeIsolated { engine?.refreshLibraryMetadata() }
    }
    player.restore()
    // Screenshot and UI-review runs (CI, Device Hub): start with the demo collection playing.
    if ProcessInfo.processInfo.arguments.contains("-CoverFlowDemoSession") {
      let engine = player
      Task { @MainActor in
        if library.albums.isEmpty {
          await library.addDemoCollection()
          library.lastReport = nil
        }
        if let first = library.albums.first, engine.currentTrackID == nil {
          engine.play(albumID: first.id)
          engine.pause()
        }
        // -CoverFlowShow albumView | immersive | album | <tab> opens that view for review.
        switch UserDefaults.standard.string(forKey: "CoverFlowShow") ?? "" {
        case "albumView": self.nowPlaying = true
        case "immersive": self.immersive = true
        case "album":
          self.albumPanel = library.albums.first?.id
          self.albumSheet = library.albums.first?.id
        case let value: if let tab = MobileTab(rawValue: value) { self.tab = tab }
        }
      }
    }
    let albumIDs = Set(library.albums.map(\.id))
    Task.detached(priority: .background) { await MobileSceneStore.shared.prune(keeping: albumIDs) }
    observers.append(
      NotificationCenter.default.addObserver(
        forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
      ) { [weak self] note in
        MainActor.assumeIsolated {
          guard let self, let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: raw)
          else { return }
          if type == .began {
            self.resumeAfterInterruption = self.player.isPlaying
            self.player.pause()
          } else {
            let options = AVAudioSession.InterruptionOptions(
              rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            if self.resumeAfterInterruption, options.contains(.shouldResume), !self.player.isPlaying
            {
              self.player.togglePlayPause()
            }
            self.resumeAfterInterruption = false
          }
        }
      })
    observers.append(
      NotificationCenter.default.addObserver(
        forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
      ) { [weak self] note in
        if note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
          == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
        {
          MainActor.assumeIsolated { self?.player.pause() }
        }
      })
  }
  func save() {
    library.saveNow()
    player.saveNow()
  }
}
@main struct CoverFlowiPadApp: App {
  @StateObject private var app = MobileEnvironment()
  @Environment(\.scenePhase) private var phase
  @AppStorage("mobile.theme") private var theme = "system"
  @AppStorage(ColorTheme.defaultsKey) private var colorTheme = ColorTheme.brass.id
  var body: some Scene {
    WindowGroup {
      MobileRootView().id(colorTheme).environmentObject(app).environmentObject(app.library).environmentObject(
        app.player
      ).environmentObject(app.scrobbler).environmentObject(app.lyrics).environmentObject(
        app.karaoke
      ).environmentObject(app.artworkTags).environmentObject(app.lyricsLibrary)
      .tint(MobilePalette.brass)
      .preferredColorScheme(theme == "dark" ? .dark : theme == "light" ? .light : nil)
      .onChange(of: phase) { _, value in if value != .active { app.save() } }
      .onOpenURL { url in Task { await app.library.importURLs([url]) } }
    }
  }
}
