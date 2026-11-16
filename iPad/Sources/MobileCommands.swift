import SwiftUI

/// The Mac app's keyboard shortcuts, for hardware keyboards on iPhone and iPad.
/// Hold ⌘ on iPad to list them. Unmodified keys (arrows, Return, Space) are handled
/// by the focused Cover Flow, Album View and karaoke views so text fields keep them.
struct MobileKeyCommands: View {
  let layout: MobileLayoutClass
  @EnvironmentObject private var app: MobileEnvironment
  @EnvironmentObject private var player: PlayerEngine
  @AppStorage("mobile.browse") private var browse = "coverFlow"
  var body: some View {
    ZStack {
      Group {
        key("Play or Pause", "p", .command) { player.togglePlayPause() }
        key("Next Track", .rightArrow, .command) { player.next() }
        key("Previous Track", .leftArrow, .command) { player.previous() }
        key("Skip Forward 10 Seconds", .rightArrow, [.command, .option]) { player.skip(by: 10) }
        key("Skip Back 10 Seconds", .leftArrow, [.command, .option]) { player.skip(by: -10) }
        key("Increase Volume", .upArrow, .command) { player.nudgeVolume(0.1) }
        key("Decrease Volume", .downArrow, .command) { player.nudgeVolume(-0.1) }
        key("Mute", .downArrow, [.command, .option]) { player.toggleMute() }
        key("Shuffle", "s", [.command, .control]) { player.toggleShuffle() }
        key("Repeat", "r", [.command, .control]) { player.cycleRepeat() }
      }
      Group {
        key("Cover Flow", "1", .command) { show(browse: "coverFlow") }
        key("Grid", "2", .command) { show(browse: "grid") }
        key("Music Visualizer", "3", .command) { app.tab = .visualizer }
        key("Lyrics", "4", .command) { app.tab = .lyrics }
        key("Karaoke", "5", .command) { app.tab = .karaoke }
        key("Up Next", "u", .command) { app.tab = .queue }
        key("Show Playing Album", "l", .command) {
          app.tab = .library
          app.revealPlaying += 1
        }
        key("Search Music", "f", .command) {
          app.tab = .library
          app.searchPresented = true
        }
        key("Settings", ",", .command) { app.tab = .settings }
      }
      Group {
        key("Album View", "a", [.command, .shift]) { app.nowPlaying.toggle() }
        key("Compact Album View", "1", [.command, .option]) {
          app.nowPlaying = false
          app.immersive = false
        }
        key("Large Album View", "2", [.command, .option]) {
          app.immersive = false
          app.nowPlaying = true
        }
        key("Immersive Album View", "3", [.command, .option]) {
          app.nowPlaying = false
          app.immersive = true
        }
      }
    }
    .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
  }
  private func show(browse value: String) {
    browse = value
    app.tab = .library
  }
  private func key(
    _ title: String, _ key: KeyEquivalent, _ modifiers: EventModifiers,
    action: @escaping () -> Void
  ) -> some View {
    Button(title, action: action).keyboardShortcut(key, modifiers: modifiers)
  }
}

/// About Cover Flow: version, what's included, credits and links.
struct MobileAboutView: View {
  private var version: String {
    let info = Bundle.main.infoDictionary
    let short = info?["CFBundleShortVersionString"] as? String ?? "—"
    let build = info?["CFBundleVersion"] as? String ?? "—"
    return "\(short) (\(build))"
  }
  var body: some View {
    List {
      Section {
        VStack(alignment: .leading, spacing: 8) {
          Text("Cover Flow").font(.system(.largeTitle, design: .serif).weight(.semibold))
          Text("Browse your music by its covers.").foregroundStyle(.secondary)
          Text("Version \(version)").font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
        }.padding(.vertical, 8)
      }
      Section("Included") {
        feature("square.stack.3d.up.fill", "Cover Flow and Grid", "Touch and keyboard browsing, album selection, search and sorting")
        feature("play.rectangle", "Album View", "Compact, Large and Immersive, with artwork scenes")
        feature("waveform", "Gapless playback", MobileFormats.summary)
        feature("quote.bubble", "Lyrics", "Synced LRC and plain text, LRCLIB search and download")
        feature("mic.fill", "Karaoke and Stem Mix", "Native MDX models, imported Mac stems and Demucs sets")
        feature("sparkles", "Visualizer", "Four Metal styles with Auto and full screen")
        feature("photo", "Artwork", MobileArtworkTagging.available
          ? "Replace, download and embed covers in imported files"
          : "Replace and download covers for your collection")
        feature("dot.radiowaves.left.and.right", "Last.fm", "Scrobbling with pending retries")
        feature("iphone.gen3", "iPhone Duo", "Outer and inner displays, book and tabletop postures")
      }
      Section("Credits") {
        Text("ONNX Runtime 1.24.2 © Microsoft, MIT license.")
        if MobileFormats.extended {
          Text("FFmpeg 7.1.2, decoder-only build, LGPL 2.1. Source: ffmpeg.org.")
        }
        if MobileArtworkTagging.available {
          Text("TagLib 2.3.2, LGPL 2.1 / MPL 1.1.")
        }
        Text("Lyrics search by LRCLIB. Artwork search by MusicBrainz and the Cover Art Archive.")
      }.font(.footnote)
      Section {
        Link("Releases", destination: URL(string: "https://github.com/dustalexw/cover-flow/releases")!)
        Link("Project & Source", destination: URL(string: "https://github.com/dustalexw/cover-flow")!)
        Link("Report an Issue", destination: URL(string: "https://github.com/dustalexw/cover-flow/issues")!)
      }
    }.navigationTitle("About Cover Flow")
  }
  private func feature(_ icon: String, _ title: String, _ detail: String) -> some View {
    Label {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
        Text(detail).font(.caption).foregroundStyle(.secondary)
      }
    } icon: {
      Image(systemName: icon).foregroundStyle(MobilePalette.brass)
    }
  }
}

/// Which audio formats this build plays.
enum MobileFormats {
  static var extended: Bool {
    #if canImport(CFFmpegAudio)
      return true
    #else
      return false
    #endif
  }
  static var summary: String {
    extended
      ? "MP3, AAC, ALAC, FLAC, WAV, AIFF, Opus, Vorbis, Monkey’s Audio, WavPack, WMA, DSD, Musepack, TTA and more"
      : "MP3, AAC, ALAC, FLAC, WAV, AIFF and Opus"
  }
}
