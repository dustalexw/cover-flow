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

/// Where a back cover or disc image was found.
enum ArtSource: String, Sendable, Equatable {
    case coverArtArchive = "Cover Art Archive"
    case theAudioDB = "TheAudioDB"
    case fanartTV = "fanart.tv"
}

/// A back cover or disc image found online: a scan from the Cover Art Archive, or
/// disc art (cut-out CD/vinyl images) from TheAudioDB or fanart.tv.
struct CoverArtExtra: Sendable, Equatable {
    let kind: AlbumImageKind
    /// Disc number for disc art.
    let disc: Int?
    let url: URL
    var source: ArtSource = .coverArtArchive
}

struct ArtworkMatch: Identifiable, Sendable {
    let id: UUID
    let title: String
    let artist: String
    let year: String
}

enum MusicLookupError: LocalizedError {
    case itemRemoved, noResults, tooLarge, unavailable(Int), invalidResponse, rateLimited(Int), busy(Int)
    var errorDescription: String? {
        switch self {
        case .itemRemoved: return "This track or album was removed from the collection."
        case .noResults: return "No matches found. Try changing the title or artist."
        case .tooLarge: return "The download is too large to import."
        case .unavailable(let code):
            return code == 404 ? "No artwork is available for this edition. Try another result." : "The service is unavailable (\(code)). Try again later."
        case .invalidResponse: return "The service returned an unreadable response. Try again later."
        case .rateLimited(let seconds):
            return "The service asked us to wait \(seconds) \(seconds == 1 ? "second" : "seconds") before searching again."
        case .busy:
            return "The service is busy right now. Try searching again in a moment."
        }
    }
    /// Seconds the service asked us to wait, for errors worth retrying.
    var retryDelay: Int? {
        switch self {
        case .rateLimited(let seconds), .busy(let seconds): return seconds
        default: return nil
        }
    }
}

/// User-initiated metadata lookups only. Serial requests, service spacing and
/// Retry-After apply across all windows; no music files are sent to either service.
actor MusicLookupClient {
    static let shared = MusicLookupClient()
    static var userAgent: String { "CoverFlow/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.7.0") (https://github.com/dustalexw/cover-flow)" }
    static let maxRetries = 3
    static let maxAutoRetryWait = 5
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

    /// Back cover and disc images of the release the group's cover comes from. Empty
    /// when the release has none (or the group has no cover art at all).
    func coverExtras(_ match: ArtworkMatch) async throws -> [CoverArtExtra] {
        let url = URL(string: "https://coverartarchive.org/release-group/\(match.id.uuidString.lowercased())")!
        do {
            return try Self.parseCoverExtras(try await fetch(url, limit: 2 * 1024 * 1024, accept: "application/json"))
        } catch MusicLookupError.unavailable(let code) where code == 404 {
            return []
        }
    }

    /// Back cover and disc art for an album from every source: the Cover Art Archive
    /// (the group's chosen release first, then other editions that have a back cover or
    /// more scans), TheAudioDB, and fanart.tv when a personal API key is set. Sources that
    /// fail or have nothing are skipped.
    func albumExtras(_ match: ArtworkMatch, fanartKey: String? = nil) async -> [CoverArtExtra] {
        let group = match.id.uuidString.lowercased()
        var archive = (try? await coverExtras(match)) ?? []
        func has(_ list: [CoverArtExtra], _ kind: AlbumImageKind) -> Bool { list.contains { $0.kind == kind } }
        if !has(archive, .back) || !has(archive, .disc) {
            // The group's index only covers one release; other editions often have more scans.
            let browse = URL(string: "https://musicbrainz.org/ws/2/release?release-group=\(group)&fmt=json&limit=100")!
            let releases = (try? Self.parseReleaseBrowse(try await fetch(browse, limit: 4 * 1024 * 1024))) ?? []
            for release in releases.prefix(4) {
                if has(archive, .back) && has(archive, .disc) { break }
                let url = URL(string: "https://coverartarchive.org/release/\(release)")!
                guard let found = try? Self.parseCoverExtras(try await fetch(url, limit: 2 * 1024 * 1024, accept: "application/json")) else { continue }
                if !has(archive, .back), let back = found.first(where: { $0.kind == .back }) { archive.append(back) }
                // Take every disc from one edition so a set's discs match each other.
                if !has(archive, .disc) { archive += found.filter { $0.kind == .disc } }
            }
        }
        var audioDB: [CoverArtExtra] = []
        let byGroup = URL(string: "https://www.theaudiodb.com/api/v1/json/\(Self.audioDBKey)/album-mb.php?i=\(group)")!
        if let data = try? await fetch(byGroup, limit: 1024 * 1024) { audioDB = (try? Self.parseAudioDB(data)) ?? [] }
        if audioDB.isEmpty, let data = try? await fetch(Self.audioDBSearchURL(title: match.title, artist: match.artist), limit: 1024 * 1024) {
            audioDB = (try? Self.parseAudioDB(data)) ?? []
        }
        var fanart: [CoverArtExtra] = []
        if let key = fanartKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty,
           var parts = URLComponents(string: "https://webservice.fanart.tv/v3/music/albums/\(group)") {
            parts.queryItems = [URLQueryItem(name: "api_key", value: key)]
            if let url = parts.url, let data = try? await fetch(url, limit: 1024 * 1024) {
                fanart = (try? Self.parseFanart(data, releaseGroup: group)) ?? []
            }
        }
        return Self.mergeExtras(archive: archive, audioDB: audioDB, fanart: fanart)
    }

    /// The release group that best matches an album, or nil when no result's title and
    /// artist agree with it closely enough to pick without asking.
    func bestMatch(title: String, artist: String) async throws -> ArtworkMatch? {
        let results: [ArtworkMatch]
        do { results = try await artwork(title: title, artist: artist) }
        catch MusicLookupError.noResults { return nil }
        return Self.pickMatch(results, title: title, artist: artist)
    }

    nonisolated static func pickMatch(_ results: [ArtworkMatch], title: String, artist: String) -> ArtworkMatch? {
        let wantedTitle = normalized(title, dropEdition: true)
        let wantedArtist = normalized(artist, dropEdition: false)
        let various = ["various artists", "various", ""].contains(wantedArtist)
        return results.first { match in
            guard normalized(match.title, dropEdition: true) == wantedTitle else { return false }
            if various { return true }
            let found = normalized(match.artist, dropEdition: false)
            return found == wantedArtist || found.contains(wantedArtist) || wantedArtist.contains(found)
        }
    }

    /// Lowercased letters and digits; optionally without a trailing "(Deluxe Edition)" or "[Remastered]".
    nonisolated static func normalized(_ value: String, dropEdition: Bool) -> String {
        var text = value.lowercased().folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
        if dropEdition, let range = text.range(of: #"\s*[\(\[][^\)\]]*[\)\]]\s*$"#, options: .regularExpression), range.lowerBound != text.startIndex {
            text.removeSubrange(range)
        }
        text = text.replacingOccurrences(of: "&", with: "and")
        return String(text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// TheAudioDB's public key; limited to 30 requests a minute, spaced in perform().
    static let audioDBKey = "123"

    nonisolated static func audioDBSearchURL(title: String, artist: String) -> URL {
        var parts = URLComponents(string: "https://www.theaudiodb.com/api/v1/json/\(audioDBKey)/searchalbum.php")!
        parts.queryItems = [URLQueryItem(name: "s", value: artist.trimmingCharacters(in: .whitespacesAndNewlines)),
                            URLQueryItem(name: "a", value: title.trimmingCharacters(in: .whitespacesAndNewlines))]
        return parts.url!
    }

    /// Release IDs in a MusicBrainz release browse that have a back cover or more than
    /// one image in the Cover Art Archive, best first.
    nonisolated static func parseReleaseBrowse(_ data: Data) throws -> [String] {
        struct Browse: Decodable { let releases: [Release] }
        struct Release: Decodable {
            let id: String
            let art: Art?
            enum CodingKeys: String, CodingKey { case id; case art = "cover-art-archive" }
        }
        struct Art: Decodable { let back: Bool?; let count: Int? }
        guard let browse = try? JSONDecoder().decode(Browse.self, from: data) else { throw MusicLookupError.invalidResponse }
        return browse.releases
            .filter { UUID(uuidString: $0.id) != nil && ($0.art?.back == true || ($0.art?.count ?? 0) > 1) }
            .enumerated()
            .sorted { a, b in
                let x = a.element.art, y = b.element.art
                if (x?.back == true) != (y?.back == true) { return x?.back == true }
                if (x?.count ?? 0) != (y?.count ?? 0) { return (x?.count ?? 0) > (y?.count ?? 0) }
                return a.offset < b.offset
            }
            .map { $0.element.id.lowercased() }
    }

    /// TheAudioDB album: strAlbumBack and strAlbumCDart (a cut-out disc, disc 1).
    nonisolated static func parseAudioDB(_ data: Data) throws -> [CoverArtExtra] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MusicLookupError.invalidResponse }
        guard let album = (object["album"] as? [[String: Any]])?.first else { return [] }
        var extras: [CoverArtExtra] = []
        if let url = safeURL(album["strAlbumBack"] as? String) {
            extras.append(CoverArtExtra(kind: .back, disc: nil, url: url, source: .theAudioDB))
        }
        if let url = safeURL(album["strAlbumCDart"] as? String) {
            extras.append(CoverArtExtra(kind: .disc, disc: 1, url: url, source: .theAudioDB))
        }
        return extras
    }

    /// fanart.tv album: "cdart" images, the most liked per disc.
    nonisolated static func parseFanart(_ data: Data, releaseGroup: String) throws -> [CoverArtExtra] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MusicLookupError.invalidResponse }
        let albums = object["albums"] as? [String: Any] ?? [:]
        let album = (albums[releaseGroup] ?? albums.first(where: { $0.key.lowercased() == releaseGroup })?.value) as? [String: Any]
        let art = album?["cdart"] as? [[String: Any]] ?? []
        func int(_ value: Any?) -> Int? { (value as? Int) ?? (value as? String).flatMap { Int($0) } }
        var best: [Int: (likes: Int, url: URL)] = [:]
        for item in art {
            guard let url = safeURL(item["url"] as? String) else { continue }
            let disc = max(1, int(item["disc"]) ?? 1), likes = int(item["likes"]) ?? 0
            if best[disc] == nil || likes > best[disc]!.likes { best[disc] = (likes, url) }
        }
        return best.keys.sorted().map { CoverArtExtra(kind: .disc, disc: $0, url: best[$0]!.url, source: .fanartTV) }
    }

    /// One back cover (a real scan first) and one image per disc. Cut-out disc art from
    /// fanart.tv or TheAudioDB is preferred, unless the archive has scans of more discs.
    nonisolated static func mergeExtras(archive: [CoverArtExtra], audioDB: [CoverArtExtra], fanart: [CoverArtExtra]) -> [CoverArtExtra] {
        var result: [CoverArtExtra] = []
        if let back = (archive + audioDB).first(where: { $0.kind == .back }) { result.append(back) }
        let scans = archive.filter { $0.kind == .disc }
        let cutOuts = fanart.isEmpty ? audioDB.filter { $0.kind == .disc } : fanart
        result += cutOuts.count >= scans.count && !cutOuts.isEmpty ? cutOuts : scans
        return result
    }

    /// Only image hosts of the art services are fetched, always over HTTPS.
    nonisolated static func safeURL(_ string: String?) -> URL? {
        guard let string, !string.isEmpty, var parts = URLComponents(string: string), let host = parts.host?.lowercased() else { return nil }
        let trusted = ["coverartarchive.org", "archive.org", "theaudiodb.com", "fanart.tv"]
        guard trusted.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return nil }
        parts.scheme = "https"
        return parts.url
    }

    func extraImage(_ extra: CoverArtExtra) async throws -> Data {
        try await fetch(extra.url, limit: 25 * 1024 * 1024, accept: "image/*")
    }

    /// Reads a Cover Art Archive index: the first "Back" image, and every "Medium" image
    /// numbered by its comment ("Disc 2", "CD 2") or by its order. Only Cover Art
    /// Archive / Internet Archive URLs are accepted, upgraded to HTTPS, preferring the
    /// 1200-pixel thumbnail.
    nonisolated static func parseCoverExtras(_ data: Data) throws -> [CoverArtExtra] {
        struct Index: Decodable { let images: [Image] }
        struct Image: Decodable {
            let types: [String]?
            let back: Bool?
            let image: String?
            let thumbnails: [String: String]?
            let comment: String?
        }
        guard let index = try? JSONDecoder().decode(Index.self, from: data) else { throw MusicLookupError.invalidResponse }
        func safeURL(_ string: String?) -> URL? {
            guard let url = Self.safeURL(string), let host = url.host?.lowercased(),
                  host == "coverartarchive.org" || host == "archive.org" || host.hasSuffix(".archive.org") else { return nil }
            return url
        }
        func discNumber(_ comment: String?) -> Int? {
            guard let comment else { return nil }
            let pattern = try? NSRegularExpression(pattern: #"(?:disc|disk|cd|lp|vinyl|side)\s*([0-9]{1,2})"#, options: [.caseInsensitive])
            let range = NSRange(comment.startIndex..., in: comment)
            guard let match = pattern?.firstMatch(in: comment, range: range),
                  let number = Range(match.range(at: 1), in: comment).flatMap({ Int(comment[$0]) }), number > 0 else { return nil }
            return number
        }
        var extras: [CoverArtExtra] = []
        var nextDisc = 1
        for image in index.images {
            let types = Set((image.types ?? []).map { $0.lowercased() })
            guard let url = safeURL(image.thumbnails?["1200"] ?? image.thumbnails?["large"] ?? image.image) else { continue }
            if types.contains("back") || image.back == true {
                if !extras.contains(where: { $0.kind == .back }) { extras.append(CoverArtExtra(kind: .back, disc: nil, url: url)) }
            } else if types.contains("medium") {
                var disc = discNumber(image.comment) ?? nextDisc
                while extras.contains(where: { $0.kind == .disc && $0.disc == disc }) { disc += 1 }
                extras.append(CoverArtExtra(kind: .disc, disc: disc, url: url))
                nextDisc = disc + 1
            }
        }
        return extras
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

    private func fetch(_ url: URL, limit: Int, accept: String? = nil) async throws -> Data {
        let previous = pending
        let work = Task<Data, Error> {
            if let previous { _ = try? await previous.value }
            // LRCLIB in particular answers brief overloads with 503 + "Retry-After: 1".
            // Short waits are retried quietly; long ones go back to the user.
            var attempt = 0
            while true {
                try Task.checkCancellation()
                do { return try await self.perform(url, limit: limit, accept: accept) }
                catch let error as MusicLookupError {
                    guard attempt < Self.maxRetries, let wait = error.retryDelay, wait <= Self.maxAutoRetryWait else { throw error }
                    attempt += 1
                    // perform() already waits out Retry-After; add a growing pad so retries spread out.
                    try await Task.sleep(for: .seconds(0.5 * Double(attempt)))
                }
            }
        }
        pending = work
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }
    private func perform(_ url: URL, limit: Int, accept: String? = nil) async throws -> Data {
        let host = url.host ?? ""
        let delay = (nextRequest[host] ?? .distantPast).timeIntervalSinceNow
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        try Task.checkCancellation()
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(accept ?? (host == "coverartarchive.org" ? "image/*" : "application/json"), forHTTPHeaderField: "Accept")
        // Set a minimum gap even if the request fails; MB requires at most one per second.
        // MusicBrainz allows one request a second; TheAudioDB's public key 30 a minute.
        let gap = host == "musicbrainz.org" ? 1.1 : host.hasSuffix("theaudiodb.com") ? 2.1 : 0.35
        defer { nextRequest[host] = max(nextRequest[host] ?? .distantPast, Date().addingTimeInterval(gap)) }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw MusicLookupError.invalidResponse }
        if response.statusCode == 429 || response.statusCode == 503 {
            let value = response.value(forHTTPHeaderField: "Retry-After") ?? ""
            let date = DateFormatter()
            date.locale = Locale(identifier: "en_US_POSIX"); date.timeZone = TimeZone(secondsFromGMT: 0)
            date.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            let delay = max(1, Double(value) ?? date.date(from: value)?.timeIntervalSinceNow ?? 5)
            nextRequest[host] = Date().addingTimeInterval(delay)
            let seconds = Int(ceil(delay))
            throw response.statusCode == 503 ? MusicLookupError.busy(seconds) : MusicLookupError.rateLimited(seconds)
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
