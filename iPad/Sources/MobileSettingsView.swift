import SwiftUI

struct MobileSettingsView: View {
  @EnvironmentObject private var scrobbler: LastFmScrobbler
  @EnvironmentObject private var library: LibraryStore
  @AppStorage("mobile.theme") private var theme = "system"
  @State private var apiKey = ""
  @State private var secret = ""
  @State private var error: String?
  @State private var confirmDisconnect = false
  @State private var showLyricsLibrary = false
  @AppStorage(ExtraArtSettings.fanartKeyDefaultsKey) private var fanartKey = ""
  @AppStorage(CoverTurnStyle.defaultsKey) private var turnStyle: CoverTurnStyle = .flipWithDiscs
  var body: some View {
    Form {
      Section("Appearance") {
        Picker("Theme", selection: $theme) {
          ForEach(AppTheme.allCases) { Text($0.label).tag($0.rawValue) }
        }
      }
      Section("Last.fm") {
        if scrobbler.connected {
          LabeledContent("Account", value: scrobbler.username)
          Toggle("Scrobble listening", isOn: $scrobbler.enabled)
          LabeledContent("Pending listens", value: String(scrobbler.pendingCount))
          Button("Retry Pending Listens") { scrobbler.retryPending() }
          Button("Disconnect", role: .destructive) { confirmDisconnect = true }
        } else if scrobbler.configured {
          if scrobbler.authorizationPending {
            Button("Finish Connecting") { Task { await scrobbler.finishConnection() } }
            Button("Cancel") { scrobbler.cancelConnection() }
          } else {
            Button("Connect Last.fm") { Task { await scrobbler.beginConnection() } }
          }
        }
        DisclosureGroup(scrobbler.configured ? "Change API credentials" : "Set Up Last.fm") {
          TextField("API key", text: $apiKey).textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          SecureField("Shared secret", text: $secret).textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          Button("Save API Credentials") {
            do {
              try scrobbler.configure(apiKey: apiKey, secret: secret)
              apiKey = ""
              secret = ""
              error = nil
            } catch { self.error = error.localizedDescription }
          }
          Link(
            "Create a Last.fm API account",
            destination: URL(string: "https://www.last.fm/api/account/create")!)
        }
        if !scrobbler.status.isEmpty {
          Text(scrobbler.status).font(.footnote).foregroundStyle(.secondary)
        }
        if let error { Text(error).font(.footnote).foregroundStyle(.red) }
      }.disabled(scrobbler.busy)
      Section("Collection") {
        LabeledContent("Albums", value: String(library.albums.count))
        LabeledContent("Tracks", value: String(library.tracks.count))
        Button("Add Demo Collection") { Task { await library.addDemoCollection() } }.disabled(
          library.importing)
        Text(
          "Import audio files or folders from Files and iCloud Drive. Cover Flow saves owned copies; deleting the source later won’t remove the imported music."
        ).font(.footnote).foregroundStyle(.secondary)
      }
      Section("Back Covers & Disc Art") {
        Picker("When turning a cover over", selection: $turnStyle) {
          ForEach(CoverTurnStyle.allCases) { Text($0.label).tag($0) }
        }
        Text(
          "Tap the flip button under the cover in Cover Flow, tap the cover in an album, or press F on a keyboard. Cover Flow finds images named like “Back.jpg” or “CD1.png” beside the music you import (and in Scans or Artwork folders), pictures embedded in the files, and online in the Cover Art Archive and TheAudioDB."
        ).font(.footnote).foregroundStyle(.secondary)
        TextField("fanart.tv API key (optional)", text: $fanartKey)
          .textInputAutocapitalization(.never).autocorrectionDisabled()
        Text("A free personal key from fanart.tv adds its large collection of disc art.")
          .font(.footnote).foregroundStyle(.secondary)
        Button("Find Missing Back Covers & Disc Art") {
          library.findExtraArt(library.albums.filter { library.needsExtraArt($0) }.map(\.id))
        }.disabled(library.extraArtProgress != nil || library.importing || library.albums.allSatisfy(\.isDemo))
      }
      Section("Lyrics") {
        Button("Lyrics Library…") { showLyricsLibrary = true }
        Text(
          "As in Lyripass: see which tracks have synced or plain lyrics, get lyrics for many tracks at once from LRCLIB, sync lines and words to the music in the editor, and export .lrc or .txt files to Files."
        ).font(.footnote).foregroundStyle(.secondary)
      }
      Section("Karaoke on iPhone or iPad") {
        Text(
          "MDX ONNX models including Inst_HQ_5 process locally with Core ML GPU enabled and CPU fallback. Demucs (4 or 6 stems) downloads once from Karaoke → Add and separates drums, bass, guitar, piano, vocals and other on this device. Converted waveform Core ML models can also be imported. Raw Becruily .ckpt files cannot run on iPhone or iPad. Prepare audio on your Mac and import vocals.wav and instrumental.wav, or a whole Demucs stem set for instrument isolation and Stem Mix."
        ).font(.footnote)
        Text("Keep the app open while preparing. No audio or model files are uploaded.").font(
          .footnote
        ).foregroundStyle(.secondary)
      }
      Section("About") {
        NavigationLink {
          MobileAboutView()
        } label: {
          LabeledContent(
            "About Cover Flow",
            value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
              ?? "")
        }
        LabeledContent("Audio formats") {
          Text(MobileFormats.summary).multilineTextAlignment(.trailing)
        }.font(.footnote)
      }
    }.confirmationDialog(
      "Disconnect Last.fm and clear pending listens?", isPresented: $confirmDisconnect,
      titleVisibility: .visible
    ) { Button("Disconnect", role: .destructive) { scrobbler.disconnect() } }
    .sheet(isPresented: $showLyricsLibrary) { MobileLyricsLibraryView() }
  }
}
