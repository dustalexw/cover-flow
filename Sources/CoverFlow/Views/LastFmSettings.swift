import SwiftUI

struct LastFmSettings: View {
    @EnvironmentObject private var lastfm: LastFmScrobbler
    @State private var showSetup = false
    @State private var apiKey = ""
    @State private var secret = ""
    @State private var setupError: String?

    var body: some View {
        Section("Last.fm") {
            Text("Send your listening history to Last.fm. Songs count after you listen to half the track or four minutes; pauses and seeking don’t count.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if lastfm.connected {
                Label("Connected as \(lastfm.username)", systemImage: "checkmark.circle.fill")
                Toggle("Scrobble my listening", isOn: $lastfm.enabled)
                HStack {
                    Button("Disconnect") { lastfm.disconnect() }
                    if lastfm.pendingCount > 0 {
                        Text("\(lastfm.pendingCount) pending").foregroundStyle(.secondary)
                        Button("Retry Now") { lastfm.retryPending() }.disabled(!lastfm.enabled)
                    }
                }
                Text("Disconnecting clears pending listens on this Mac.").font(.caption).foregroundStyle(.secondary)
            } else if lastfm.authorizationPending {
                HStack {
                    Button("Finish Connecting") { Task { await lastfm.finishConnection() } }
                    Button("Cancel") { lastfm.cancelConnection() }
                }
                .disabled(lastfm.busy)
            } else {
                HStack {
                    Button("Connect Last.fm") { Task { await lastfm.beginConnection() } }
                        .disabled(!lastfm.configured || lastfm.busy)
                    Button(lastfm.configured ? "Change App Credentials…" : "Set Up Last.fm…") { showSetup = true }
                        .disabled(lastfm.busy)
                }
            }
            if lastfm.busy { ProgressView().controlSize(.small) }
            if !lastfm.status.isEmpty { Text(lastfm.status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            Text("Credentials are kept in Keychain. Eligible listens wait on this Mac when offline. Demo tracks and tracks with incomplete tags are skipped.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .sheet(isPresented: $showSetup) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Set Up Last.fm").font(.title2.bold())
                Text("Register a Last.fm API account for Cover Flow, then enter its API key and shared secret. Last.fm uses these to identify the player; you’ll authorize your listening account in your browser next.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Link("Get app credentials from Last.fm", destination: URL(string: "https://www.last.fm/api/account/create")!)
                TextField("API key", text: $apiKey)
                SecureField("Shared secret", text: $secret)
                Text("Changing app credentials disconnects your account and clears pending listens. Your Last.fm password is never entered here.")
                    .font(.caption).foregroundStyle(.secondary)
                if let setupError { Text(setupError).foregroundStyle(.red).font(.caption) }
                HStack {
                    Spacer()
                    Button("Cancel") { showSetup = false; secret = ""; apiKey = ""; setupError = nil }
                        .keyboardShortcut(.cancelAction)
                    Button("Save Setup") {
                        do {
                            try lastfm.configure(apiKey: apiKey, secret: secret)
                            showSetup = false; secret = ""; apiKey = ""; setupError = nil
                        } catch { setupError = error.localizedDescription }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(apiKey.isEmpty || secret.isEmpty)
                }
            }
            .padding(24)
            .frame(width: 440)
        }
    }
}
