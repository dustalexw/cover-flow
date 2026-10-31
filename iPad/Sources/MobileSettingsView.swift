import SwiftUI

struct MobileSettingsView: View {
  @EnvironmentObject private var scrobbler: LastFmScrobbler
  @EnvironmentObject private var library: LibraryStore
  @AppStorage("mobile.theme") private var theme = "system"
  @State private var apiKey = ""
  @State private var secret = ""
  @State private var error: String?
  @State private var confirmDisconnect = false
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
      Section("Karaoke on iPhone or iPad") {
        Text(
          "MDX ONNX models including Inst_HQ_5 process locally with Core ML GPU enabled and CPU fallback. Converted waveform Core ML models can also be imported. Raw Becruily .ckpt files cannot run on iPhone or iPad. Prepare audio on your Mac and import vocals.wav and instrumental.wav to use those stems here."
        ).font(.footnote)
        Text("Keep the app open while preparing. No audio or model files are uploaded.").font(
          .footnote
        ).foregroundStyle(.secondary)
      }
      Section("About") {
        LabeledContent("Cover Flow for iOS", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.2.0")
        Text(
          "Touch Cover Flow · album grid · gapless playback · AirPlay · artwork · synced LRC lyrics · karaoke · Last.fm · audio visualizer"
        ).font(.footnote).foregroundStyle(.secondary)
        Link(
          "Project & Source", destination: URL(string: "https://github.com/dustalexw/cover-flow")!)
        Link(
          "Report an Issue",
          destination: URL(string: "https://github.com/dustalexw/cover-flow/issues")!)
        Text(
          "Native MDX processing uses ONNX Runtime 1.24.2, © Microsoft, under the MIT license. Its license is included with this app."
        ).font(.caption).foregroundStyle(.secondary)
      }
    }.confirmationDialog(
      "Disconnect Last.fm and clear pending listens?", isPresented: $confirmDisconnect,
      titleVisibility: .visible
    ) { Button("Disconnect", role: .destructive) { scrobbler.disconnect() } }
  }
}
