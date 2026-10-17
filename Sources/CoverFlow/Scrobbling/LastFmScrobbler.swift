#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Combine
import Foundation

@MainActor
final class LastFmScrobbler: ObservableObject {
    @Published var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: "lastfmEnabled")
            progress = nil
            sentNowPlaying = false
            nowPlaying?.cancel(); nowPlaying = nil
            if enabled { flush() }
        }
    }
    @Published private(set) var username: String
    @Published private(set) var connected: Bool
    @Published private(set) var configured: Bool
    @Published private(set) var authorizationPending = false
    @Published private(set) var busy = false
    @Published private(set) var status = ""
    @Published private(set) var pendingCount = 0

    private var credentials: LastFmCredentials
    private var token: String?
    private var revision = UUID()
    private let api: LastFmAPI
    private let defaults: UserDefaults
    private let storageURL: URL
    private let saveCredentials: (LastFmCredentials) throws -> Void
    private let openURL: (URL) -> Bool
    private var records: [ScrobbleRecord] = []
    private var upload: Task<Void, Never>?
    private var retry: Task<Void, Never>?
    private var retryAfter = Date.distantPast
    private var retryDelay: Double = 30
    private var track: Track?
    private var progress: ScrobbleProgress?
    private var sentNowPlaying = false
    private var nowPlaying: Task<Void, Never>?
    private var playbackRevision = UUID()

    init(api: LastFmAPI = LastFmAPI(), defaults: UserDefaults = .standard,
         storageURL: URL = AppPaths.root.appendingPathComponent("LastfmPending.json"),
         initialCredentials: LastFmCredentials = LastFmKeychain.load() ?? LastFmCredentials(apiKey: "", secret: ""),
         saveCredentials: @escaping (LastFmCredentials) throws -> Void = LastFmKeychain.save,
         openURL: @escaping (URL) -> Bool = { url in MainActor.assumeIsolated { LastFmScrobbler.openBrowser(url) } }) {
        self.api = api
        self.defaults = defaults
        self.storageURL = storageURL
        self.saveCredentials = saveCredentials
        self.openURL = openURL
        credentials = initialCredentials
        username = credentials.username
        connected = credentials.connected
        configured = credentials.configured
        enabled = defaults.bool(forKey: "lastfmEnabled")
        if let data = try? Data(contentsOf: storageURL), let cached = try? JSONDecoder().decode([ScrobbleRecord].self, from: data) { records = cached }
        pendingCount = records.filter { $0.username == username }.count
        retry = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                self?.flush()
            }
        }
        flush()
    }

    deinit { retry?.cancel(); upload?.cancel(); nowPlaying?.cancel() }

    static func openBrowser(_ url: URL) -> Bool {
        #if os(macOS)
        return NSWorkspace.shared.open(url)
        #else
        guard UIApplication.shared.canOpenURL(url) else { return false }
        UIApplication.shared.open(url)
        return true
        #endif
    }

    func configure(apiKey: String, secret: String) throws {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        guard key.count == 32, secret.count == 32,
              key.unicodeScalars.allSatisfy(hex.contains), secret.unicodeScalars.allSatisfy(hex.contains) else {
            throw LastFmAPIError(code: 6, message: "Enter the 32-character API key and shared secret from your Last.fm API account.")
        }
        let new = LastFmCredentials(apiKey: key, secret: secret)
        try saveCredentials(new)
        invalidateOperations()
        credentials = new
        username = ""; connected = false; configured = true; enabled = false
        records = []; persist()
        status = "Setup saved. Connect your Last.fm account."
    }

    func beginConnection() async {
        guard configured, !busy else { return }
        busy = true
        status = "Requesting Last.fm authorization…"
        let version = revision
        defer { if revision == version { busy = false } }
        do {
            var auth = credentials; auth.sessionKey = ""
            let reply = try await api.call("auth.getToken", credentials: auth)
            guard revision == version else { return }
            guard let token = reply.token, !token.isEmpty else { throw LastFmAPIError(code: 503, message: "Last.fm didn’t return an authorization token.") }
            var url = URLComponents(string: "https://www.last.fm/api/auth/")!
            url.queryItems = [URLQueryItem(name: "api_key", value: credentials.apiKey), URLQueryItem(name: "token", value: token)]
            guard openURL(url.url!) else { throw LastFmAPIError(code: 503, message: "Couldn’t open your browser. Try connecting again.") }
            self.token = token
            authorizationPending = true
            status = "Approve access in your browser, then click Finish Connecting."
        } catch { if revision == version { status = error.localizedDescription } }
    }

    func finishConnection() async {
        guard let token, authorizationPending, !busy else { return }
        busy = true
        let version = revision
        defer { if revision == version { busy = false } }
        do {
            var auth = credentials; auth.sessionKey = ""
            let reply = try await api.call("auth.getSession", parameters: ["token": token], credentials: auth)
            guard revision == version else { return }
            guard let session = reply.session, !session.key.isEmpty, !session.name.isEmpty else {
                throw LastFmAPIError(code: 503, message: "Last.fm didn’t return a session. Try again.")
            }
            var new = credentials; new.username = session.name; new.sessionKey = session.key
            try saveCredentials(new)
            credentials = new
            username = new.username; connected = true; authorizationPending = false; self.token = nil
            // A cached listen is always tied to the account that earned it.
            records.removeAll { $0.username != username }
            persist()
            retryAfter = .distantPast
            enabled = true
            status = "Connected to \(username)."
        } catch {
            guard revision == version else { return }
            if let apiError = error as? LastFmAPIError, apiError.code == 14 {
                status = "Approve access on Last.fm first, then finish connecting."
            } else { status = error.localizedDescription }
        }
    }

    func cancelConnection() {
        invalidateOperations()
        status = "Connection cancelled."
    }

    func disconnect() {
        var new = credentials; new.sessionKey = ""; new.username = ""
        do { try saveCredentials(new) } catch { status = error.localizedDescription; return }
        invalidateOperations()
        credentials = new; username = ""; connected = false; enabled = false
        records = []; persist()
        status = "Disconnected."
    }

    private func invalidateOperations() {
        revision = UUID()
        upload?.cancel(); upload = nil
        nowPlaying?.cancel(); nowPlaying = nil
        token = nil; authorizationPending = false; busy = false
    }

    func newPlayback(track: Track?, duration: Double, position: Double) {
        nowPlaying?.cancel(); nowPlaying = nil
        playbackRevision = UUID()
        self.track = track
        progress = ScrobbleProgress(duration: duration, position: position, uptime: ProcessInfo.processInfo.systemUptime)
        sentNowPlaying = false
    }

    func observe(position: Double, duration: Double, playing: Bool) {
        guard enabled, connected, let track, !track.isDemo, !track.missingMetadata,
              !track.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !track.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if progress == nil { progress = ScrobbleProgress(duration: duration, position: position, uptime: now) }
        progress?.duration = duration
        progress?.update(position: position, playing: playing, uptime: now, unixTime: Date().timeIntervalSince1970)
        if playing && !sentNowPlaying {
            sentNowPlaying = true
            let record = makeRecord(track, duration: duration, timestamp: Int(Date().timeIntervalSince1970))
            var parameters = record.parameters; parameters.removeValue(forKey: "timestamp")
            let credentials = credentials
            // Now Playing is ephemeral and is never retried or put in the outbox.
            let version = revision
            let playback = playbackRevision
            nowPlaying = Task { [weak self, api] in
                do { _ = try await api.call("track.updateNowPlaying", parameters: parameters, credentials: credentials) }
                catch {
                    guard !Task.isCancelled, let self, self.revision == version,
                          self.playbackRevision == playback else { return }
                    if let error = error as? LastFmAPIError, error.code == 9 { self.expireConnection() }
                }
            }
        }
        if progress?.claimScrobble() == true, let timestamp = progress?.timestamp {
            records.append(makeRecord(track, duration: duration, timestamp: timestamp))
            persist()
            flush()
        }
    }

    func seek(to position: Double) { progress?.seek(to: position, uptime: ProcessInfo.processInfo.systemUptime) }

    private func makeRecord(_ track: Track, duration: Double, timestamp: Int) -> ScrobbleRecord {
        ScrobbleRecord(id: UUID(), username: username, artist: track.artist, title: track.title, album: track.albumTitle,
                       albumArtist: track.albumArtist, trackNumber: track.trackNumber, duration: duration, timestamp: timestamp)
    }

    func retryPending() { retryAfter = .distantPast; flush() }

    private func expireConnection() {
        invalidateOperations()
        var new = credentials; new.sessionKey = ""
        try? saveCredentials(new)
        credentials = new; connected = false
        status = "Last.fm access expired. Reconnect to send pending listens."
    }

    private func persist() {
        pendingCount = records.filter { $0.username == username }.count
        do { try JSONEncoder().encode(records).write(to: storageURL, options: .atomic) }
        catch { status = "Couldn’t save pending scrobbles on this device." }
    }

    private func flush() {
        guard enabled, connected, upload == nil, Date() >= retryAfter else { return }
        let batch = Array(records.filter { $0.username == username }.prefix(50))
        guard !batch.isEmpty else { return }
        let credentials = credentials
        let version = revision
        upload = Task { [weak self, api] in
            var parameters: [String: String] = [:]
            for (index, record) in batch.enumerated() {
                for (key, value) in record.parameters { parameters["\(key)[\(index)]"] = value }
            }
            do {
                let reply = try await api.call("track.scrobble", parameters: parameters, credentials: credentials)
                guard let self, self.revision == version else { return }
                guard let result = reply.scrobbles,
                      (Int(result.accepted) ?? 0) + (Int(result.ignored) ?? 0) == batch.count else {
                    throw LastFmAPIError(code: 503, message: "Last.fm didn’t confirm the scrobbles. They’ll be retried.")
                }
                let ids = Set(batch.map(\.id))
                self.records.removeAll { ids.contains($0.id) }
                self.persist()
                self.retryDelay = 30
                self.status = result.ignored == "0" ? "Listening history is up to date." : "Last.fm ignored \(result.ignored) listen(s). Check track tags and your Last.fm limits."
                self.upload = nil
                self.flush()
            } catch {
                guard let self, self.revision == version else { return }
                self.upload = nil
                if let error = error as? LastFmAPIError, error.code == 9 {
                    self.expireConnection()
                } else if let error = error as? LastFmAPIError, !error.retryable {
                    // Do not repeatedly submit a permanently invalid request.
                    self.enabled = false
                    self.status = "Scrobbling paused: \(error.message)"
                } else {
                    self.retryAfter = Date().addingTimeInterval(self.retryDelay)
                    self.retryDelay = min(self.retryDelay * 2, 900)
                    self.status = "Last.fm is unavailable. \(self.pendingCount) listen(s) saved for retry."
                }
            }
        }
    }
}
