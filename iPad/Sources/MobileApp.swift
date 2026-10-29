import AVFoundation
import Combine
import SwiftUI

@MainActor final class MobileEnvironment: ObservableObject {
  let library: LibraryStore
  let scrobbler: LastFmScrobbler
  let player: PlayerEngine
  let lyrics: LyricsStore
  let karaoke: MobileKaraokeStore
  let importInbox: MobileImportInbox
  private var observers: [NSObjectProtocol] = []
  private var resumeAfterInterruption = false
  @Published var tab: MobileTab = .library
  @Published var nowPlaying = false
  init() {
    do {
      try AVAudioSession.sharedInstance().setCategory(
        .playback, mode: .default, policy: .longFormAudio,
        options: [.allowAirPlay, .allowBluetoothA2DP])
    } catch {}
    let library = LibraryStore()
    let scrobbler = LastFmScrobbler()
    self.library = library
    self.scrobbler = scrobbler
    library.load()
    player = PlayerEngine(library: library, scrobbler: scrobbler)
    lyrics = LyricsStore(directory: AppPaths.root.appendingPathComponent("Lyrics"))
    karaoke = MobileKaraokeStore(root: AppPaths.root.appendingPathComponent("Karaoke"))
    importInbox = MobileImportInbox(library: library)
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
    importInbox.start()
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
enum MobileTab: String, CaseIterable, Identifiable {
  case library, queue, lyrics, karaoke, visualizer, settings
  var id: String { rawValue }
  var title: String {
    switch self {
    case .library: return "Collection"
    case .queue: return "Up Next"
    case .lyrics: return "Lyrics"
    case .karaoke: return "Karaoke"
    case .visualizer: return "Visualizer"
    case .settings: return "Settings"
    }
  }
  var icon: String {
    switch self {
    case .library: return "square.stack.fill"
    case .queue: return "text.line.first.and.arrowtriangle.forward"
    case .lyrics: return "quote.bubble"
    case .karaoke: return "mic.fill"
    case .visualizer: return "waveform"
    case .settings: return "gearshape"
    }
  }
}
@main struct CoverFlowiPadApp: App {
  @StateObject private var app = MobileEnvironment()
  @Environment(\.scenePhase) private var phase
  @AppStorage("mobile.theme") private var theme = "system"
  var body: some Scene {
    WindowGroup {
      MobileRootView().environmentObject(app).environmentObject(app.library).environmentObject(
        app.player
      ).environmentObject(app.scrobbler).environmentObject(app.lyrics).environmentObject(
        app.karaoke
      )
      .tint(MobilePalette.brass)
      .preferredColorScheme(theme == "dark" ? .dark : theme == "light" ? .light : nil)
      .onChange(of: phase) { _, value in
        if value == .active { app.importInbox.appBecameActive() } else { app.save() }
      }
      .onOpenURL { url in app.importInbox.open(url) }
    }
  }
}
