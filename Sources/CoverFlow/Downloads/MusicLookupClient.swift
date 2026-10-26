import Foundation

struct LyricMatch: Decodable, Identifiable, Sendable {
    let id: Int
    let trackName: String
    let artistName: String
    let albumName: String
    let duration: Double
    let instrumental: Bool
    let plainLyrics: String?
    let syncedLyrics: String?
    var isSynced: Bool { !(syncedLyrics ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var text: String { isSynced ? syncedLyrics! : plainLyrics ?? "" }
}

struct ArtworkMatch: Identifiable, Sendable {
    let id: UUID
    let title: String
    let artist: String
    let year: String
}

enum MusicLookupError: LocalizedError {
    case itemRemoved, noResults, tooLarge, unavailable(Int), invalidResponse, rateLimited(Int)
    var errorDescription: String? {
        switch self {
        case .itemRemoved: return "This track or album was removed from the collection."
        case .noResults: return "No matches found. Try changing the title or artist."
        case .tooLarge: return "The download is too large to import."
        case .unavailable(let code):
            return code == 404 ? "No artwork is available for this edition. Try another result." : "The service is unavailable (\(code)). Try again later."
        case .invalidResponse: return "The service returned an unreadable response. Try again later."
        case .rateLimited(let seconds): return "The service asked us to wait \(seconds) seconds before searching again."
        }
    }
}

/// User-initiated metadata lookups only. Serial requests, service spacing and
/// Retry-After apply across all windows; no music files are sent to either service.
actor MusicLookupClient {
    static let shared = MusicLookupClient()
    static var userAgent: String { "CoverFlow/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.7.0") (https://github.com/dustalexw/cover-flow)" }
    private let session: URLSession
    private var pending: Task<Data, Error>?
    private var nextRequest: [String: Date] = [:]

    init(session: URLSession? = nil) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 45
        config.httpShouldSetCookies = false
        self.session = session ?? URLSession(configuration: config)
    }

    func lyrics(title: String, artist: String, duration: Double) async throws -> [LyricMatch] {
        let url = Self.lyricsURL(title: title, artist: artist)
        let data = try await fetch(url, limit: 8 * 1024 * 1024)
        guard let matches = try? JSONDecoder().decode([LyricMatch].self, from: data) else { throw MusicLookupError.invalidResponse }
        let reference = duration.isFinite ? max(0, duration) : 0
        let result = matches.filter { $0.duration.isFinite && (0...86_400).contains($0.duration) && !$0.instrumental && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted {
                let first = abs($0.duration - reference), second = abs($1.duration - reference)
                let firstBucket = floor(first / 2), secondBucket = floor(second / 2)
                if firstBucket != secondBucket { return firstBucket < secondBucket }
                if $0.isSynced != $1.isSynced { return $0.isSynced }
                return first == second ? $0.id < $1.id : first < second
            }
        guard !result.isEmpty else { throw MusicLookupError.noResults }
        return result
    }

    func artwork(title: String, artist: String) async throws -> [ArtworkMatch] {
        let data = try await fetch(Self.artworkURL(title: title, artist: artist), limit: 2 * 1024 * 1024)
        guard let response = try? JSONDecoder().decode(ReleaseGroups.self, from: data) else { throw MusicLookupError.invalidResponse }
        let results = response.groups.compactMap { group -> ArtworkMatch? in
            guard let id = UUID(uuidString: group.id) else { return nil }
            return ArtworkMatch(id: id, title: group.title,
                                artist: group.credits.map { $0.name ?? $0.artist?.name ?? "" }.joined(separator: ", "),
                                year: group.date ?? "")
        }
        guard !results.isEmpty else { throw MusicLookupError.noResults }
        return results
    }

    func cover(_ match: ArtworkMatch) async throws -> Data {
        // The fixed 1200px endpoint bounds image dimensions and never accepts an arbitrary URL.
        let url = URL(string: "https://coverartarchive.org/release-group/\(match.id.uuidString.lowercased())/front-1200")!
        return try await fetch(url, limit: 25 * 1024 * 1024)
    }

    nonisolated static func lyricsURL(title: String, artist: String) -> URL {
        var parts = URLComponents(string: "https://lrclib.net/api/search")!
        parts.queryItems = [URLQueryItem(name: "track_name", value: title.trimmingCharacters(in: .whitespacesAndNewlines))]
        let artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        if !artist.isEmpty { parts.queryItems?.append(URLQueryItem(name: "artist_name", value: artist)) }
        return parts.url!
    }
    nonisolated static func artworkURL(title: String, artist: String) -> URL {
        func escaped(_ value: String) -> String {
            value.map { "\\+-&|!(){}[]^\"~*?:/".contains($0) ? "\\" + String($0) : String($0) }.joined()
        }
        var parts = URLComponents(string: "https://musicbrainz.org/ws/2/release-group/")!
        let artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = "releasegroup:\"\(escaped(title))\"" + (artist.isEmpty ? "" : " AND artist:\"\(escaped(artist))\"")
        parts.queryItems = [URLQueryItem(name: "query", value: query),
                            URLQueryItem(name: "fmt", value: "json"), URLQueryItem(name: "limit", value: "12")]
        return parts.url!
    }

    private func fetch(_ url: URL, limit: Int) async throws -> Data {
        let previous = pending
        let work = Task<Data, Error> {
            if let previous { _ = try? await previous.value }
            try Task.checkCancellation()
            return try await self.perform(url, limit: limit)
        }
        pending = work
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
    private func perform(_ url: URL, limit: Int) async throws -> Data {
        let host = url.host ?? ""
        let delay = (nextRequest[host] ?? .distantPast).timeIntervalSinceNow
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        try Task.checkCancellation()
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(host == "coverartarchive.org" ? "image/*" : "application/json", forHTTPHeaderField: "Accept")
        // Set a minimum gap even if the request fails; MB requires at most one per second.
        defer { nextRequest[host] = max(nextRequest[host] ?? .distantPast, Date().addingTimeInterval(host == "musicbrainz.org" ? 1.1 : 0.35)) }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw MusicLookupError.invalidResponse }
        if response.statusCode == 429 || response.statusCode == 503 {
            let value = response.value(forHTTPHeaderField: "Retry-After") ?? ""
            let date = DateFormatter()
            date.locale = Locale(identifier: "en_US_POSIX"); date.timeZone = TimeZone(secondsFromGMT: 0)
            date.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            let delay = max(1, Double(value) ?? date.date(from: value)?.timeIntervalSinceNow ?? 5)
            nextRequest[host] = Date().addingTimeInterval(delay)
            throw MusicLookupError.rateLimited(Int(ceil(delay)))
        }
        guard (200..<300).contains(response.statusCode) else { throw MusicLookupError.unavailable(response.statusCode) }
        guard response.expectedContentLength <= Int64(limit) else { throw MusicLookupError.tooLarge }
        var data = Data()
        data.reserveCapacity(min(limit, max(0, Int(response.expectedContentLength))))
        for try await byte in bytes {
            if data.count >= limit { throw MusicLookupError.tooLarge }
            data.append(byte)
            if data.count % 16_384 == 0 { try Task.checkCancellation() }
        }
        return data
    }

    private struct ReleaseGroups: Decodable {
        let groups: [Group]
        enum CodingKeys: String, CodingKey { case groups = "release-groups" }
    }
    private struct Group: Decodable {
        let id: String; let title: String; let date: String?; let credits: [Credit]
        enum CodingKeys: String, CodingKey { case id, title; case date = "first-release-date"; case credits = "artist-credit" }
    }
    private struct Credit: Decodable {
        let name: String?; let artist: Artist?
    }
    private struct Artist: Decodable { let name: String }
}
