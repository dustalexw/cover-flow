import XCTest
@testable import CoverFlow

private final class LastFmStub: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.notConnectedToInternet) }
            let (code, body) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class LastFmTests: XCTestCase {
    private let credentials = LastFmCredentials(apiKey: String(repeating: "a", count: 32), secret: String(repeating: "b", count: 32), sessionKey: "session", username: "alice")

    private func api() -> LastFmAPI {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LastFmStub.self]
        return LastFmAPI(session: URLSession(configuration: config))
    }

    private func fields(_ request: URLRequest) -> [String: String] {
        var components = URLComponents()
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            var body = Data()
            while true {
                let read = stream.read(&bytes, maxLength: bytes.count)
                if read <= 0 { break }
                body.append(bytes, count: read)
            }
            data = body
        }
        components.percentEncodedQuery = String(data: data ?? Data(), encoding: .utf8)
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    private func onMain(_ block: @escaping @MainActor () async throws -> Void) {
        let finished = expectation(description: "Last.fm checks")
        Task { @MainActor in
            do { try await block() } catch { XCTFail(error.localizedDescription) }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 10)
    }

    func testThresholdIsHalfOrFourMinutesAndOnlyOnce() {
        var short = ScrobbleProgress(duration: 30, position: 0, uptime: 0)
        short.update(position: 0, playing: true, uptime: 0, unixTime: 1000)
        short.update(position: 30, playing: true, uptime: 30, unixTime: 1030)
        XCTAssertFalse(short.claimScrobble())
        var long = ScrobbleProgress(duration: 900, position: 0, uptime: 0)
        long.update(position: 0, playing: true, uptime: 0, unixTime: 1000)
        long.update(position: 239, playing: true, uptime: 239, unixTime: 1239)
        XCTAssertFalse(long.claimScrobble())
        long.update(position: 240, playing: true, uptime: 240, unixTime: 1240)
        XCTAssertTrue(long.claimScrobble())
        XCTAssertFalse(long.claimScrobble())
        var normal = ScrobbleProgress(duration: 100, position: 0, uptime: 0)
        normal.update(position: 0, playing: true, uptime: 0, unixTime: 1000)
        normal.update(position: 50, playing: false, uptime: 50, unixTime: 1050)
        XCTAssertTrue(normal.claimScrobble())
        XCTAssertEqual(normal.timestamp, 1000)
    }

    func testPausesAndSeeksNeverEarnListeningCredit() {
        var progress = ScrobbleProgress(duration: 200, position: 0, uptime: 0)
        progress.update(position: 0, playing: true, uptime: 0, unixTime: 1000)
        progress.update(position: 10, playing: false, uptime: 10, unixTime: 1010)
        progress.update(position: 10, playing: false, uptime: 100, unixTime: 1100)
        XCTAssertEqual(progress.listened, 10)
        progress.seek(to: 180, uptime: 100)
        progress.update(position: 180, playing: true, uptime: 100, unixTime: 1100)
        progress.update(position: 185, playing: false, uptime: 105, unixTime: 1105)
        XCTAssertEqual(progress.listened, 15)
        XCTAssertFalse(progress.claimScrobble())
    }

    func testUnannouncedPositionJumpCannotCreditSeekedTime() {
        var progress = ScrobbleProgress(duration: 200, position: 0, uptime: 0)
        progress.update(position: 0, playing: true, uptime: 0, unixTime: 1000)
        progress.update(position: 150, playing: true, uptime: 1, unixTime: 1001)
        XCTAssertLessThan(progress.listened, 2)
        XCTAssertFalse(progress.claimScrobble())
    }

    func testSigningAndFormEncoding() {
        XCTAssertEqual(LastFmAPI.signature([:], secret: "abc"), "900150983cd24fb0d6963f7d28e17f72")
        XCTAssertEqual(LastFmAPI.signature(["b": "2", "a": "1"], secret: "secret"),
                       LastFmAPI.signature(["format": "json", "api_sig": "ignored", "callback": "ignored", "a": "1", "b": "2"], secret: "secret"))
        let request = LastFmAPI.request(method: "track.scrobble", parameters: ["artist": "Björk + A&B", "track": "Title = ?"], credentials: credentials)
        let decoded = fields(request)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertNil(request.url?.query)
        XCTAssertEqual(decoded["artist"], "Björk + A&B")
        XCTAssertEqual(decoded["track"], "Title = ?")
        XCTAssertEqual(decoded["sk"], "session")
        XCTAssertFalse(String(data: request.httpBody!, encoding: .utf8)!.contains(credentials.secret))
    }

    func testHTTP200APIErrorIsStillFailure() async throws {
        LastFmStub.handler = { _ in (200, "{\"error\":9,\"message\":\"Invalid session key\"}") }
        do {
            _ = try await api().call("track.scrobble", credentials: credentials)
            XCTFail("API errors must be inspected even for HTTP 200")
        } catch let error as LastFmAPIError { XCTAssertEqual(error.code, 9) }
    }

    func testBrowserAuthorizationAndSessionPersistence() {
        onMain {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let defaults = UserDefaults(suiteName: UUID().uuidString)!
            var saved: LastFmCredentials?
            var opened: URL?
            LastFmStub.handler = { request in
                let p = self.fields(request)
                XCTAssertNil(p["sk"])
                if p["method"] == "auth.getToken" { return (200, "{\"token\":\"token\"}") }
                XCTAssertEqual(p["token"], "token")
                return (200, "{\"session\":{\"name\":\"alice\",\"key\":\"new-session\"}}")
            }
            var initial = self.credentials; initial.sessionKey = ""; initial.username = ""
            let scrobbler = LastFmScrobbler(api: self.api(), defaults: defaults, storageURL: directory.appendingPathComponent("pending.json"), initialCredentials: initial,
                                          saveCredentials: { saved = $0 }, openURL: { opened = $0; return true })
            await scrobbler.beginConnection()
            XCTAssertTrue(scrobbler.authorizationPending)
            XCTAssertEqual(opened?.host, "www.last.fm")
            XCTAssertFalse(opened!.absoluteString.contains(initial.secret))
            await scrobbler.finishConnection()
            XCTAssertTrue(scrobbler.connected)
            XCTAssertTrue(scrobbler.enabled)
            XCTAssertEqual(saved?.sessionKey, "new-session")
            XCTAssertEqual(scrobbler.username, "alice")
            scrobbler.disconnect()
            XCTAssertFalse(scrobbler.enabled)
            XCTAssertFalse(scrobbler.connected)
            XCTAssertEqual(saved?.sessionKey, "")
        }
    }

    func testOfflineOutboxSurvivesRestartAndCannotCrossAccounts() {
        onMain {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("pending.json")
            let records = [self.record(username: "alice", title: "Alice listen"), self.record(username: "bob", title: "Bob listen")]
            try JSONEncoder().encode(records).write(to: url)
            let defaults = UserDefaults(suiteName: UUID().uuidString)!
            defaults.set(true, forKey: "lastfmEnabled")
            LastFmStub.handler = { _ in throw URLError(.notConnectedToInternet) }
            var scrobbler: LastFmScrobbler? = LastFmScrobbler(api: self.api(), defaults: defaults, storageURL: url,
                                                           initialCredentials: self.credentials, saveCredentials: { _ in })
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertEqual(scrobbler?.pendingCount, 1)
            XCTAssertEqual(try JSONDecoder().decode([ScrobbleRecord].self, from: Data(contentsOf: url)), records)
            scrobbler = nil
            var sent: [String: String] = [:]
            LastFmStub.handler = { request in
                sent = self.fields(request)
                return (200, "{\"scrobbles\":{\"@attr\":{\"accepted\":\"1\",\"ignored\":\"0\"}}}")
            }
            scrobbler = LastFmScrobbler(api: self.api(), defaults: defaults, storageURL: url,
                                      initialCredentials: self.credentials, saveCredentials: { _ in })
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertEqual(sent["track[0]"], "Alice listen")
            XCTAssertNil(sent["track[1]"])
            XCTAssertEqual(scrobbler?.pendingCount, 0)
            let retained = try JSONDecoder().decode([ScrobbleRecord].self, from: Data(contentsOf: url))
            XCTAssertEqual(retained.map(\.username), ["bob"])
        }
    }

    func testExpiredSessionKeepsOutboxAndRequestsReconnect() {
        onMain {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("pending.json")
            let records = [self.record(username: "alice", title: "Pending listen")]
            try JSONEncoder().encode(records).write(to: url)
            let defaults = UserDefaults(suiteName: UUID().uuidString)!
            defaults.set(true, forKey: "lastfmEnabled")
            var saved: LastFmCredentials?
            LastFmStub.handler = { _ in (200, "{\"error\":9,\"message\":\"Invalid session key\"}") }
            let scrobbler = LastFmScrobbler(api: self.api(), defaults: defaults, storageURL: url,
                                          initialCredentials: self.credentials, saveCredentials: { saved = $0 })
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertFalse(scrobbler.connected)
            XCTAssertEqual(saved?.sessionKey, "")
            XCTAssertEqual(scrobbler.pendingCount, 1)
            XCTAssertTrue(scrobbler.status.contains("Reconnect"))
            XCTAssertEqual(try JSONDecoder().decode([ScrobbleRecord].self, from: Data(contentsOf: url)), records)
        }
    }

    private func record(username: String, title: String) -> ScrobbleRecord {
        ScrobbleRecord(id: UUID(), username: username, artist: "Artist", title: title, album: "Album", albumArtist: nil, trackNumber: 1, duration: 180, timestamp: 1700000000)
    }
}
