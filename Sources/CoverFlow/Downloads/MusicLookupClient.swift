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
enum ArtSource: String, Sendable, Equatable, Hashable, CaseIterable {
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

/// Optional fanart.tv personal API key (free at fanart.tv), which adds its disc art
/// to the online sources. Stored in preferences; it isn't a password.
enum ExtraArtSettings {
    static let fanartKeyDefaultsKey = "artwork.fanartKey"
    static var fanartKey: String? {
        let key = (UserDefaults.standard.string(forKey: fanartKeyDefaultsKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }
}

/// User-initiated metadata lookups only. Requests to each service are limited (one at
/// a time, spaced, for MusicBrainz, TheAudioDB and LRCLIB; a few at once for image
/// hosts), and Retry-After applies across all windows. No music files are sent anywhere.
actor MusicLookupClient {
    static let shared = MusicLookupClient()
    static var userAgent: String { "CoverFlow/\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.7.0") (https://github.com/dustalexw/cover-flow)" }
    static let maxRetries = 3
    static let maxAutoRetryWait = 5
    private let session: URLSession
    private var nextRequest: [String: Date] = [:]
    private var active: [String: Int] = [:]
    private var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]
    /// Recent artwork answers and images, so going back to a result is instant.
    var candidateCache: [String: [ArtCandidate]] = [:]
    private var imageCache: [URL: Data] = [:]
    private var imageCacheOrder: [URL] = []
    private var imageCacheBytes = 0

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
        do { results = try await artwork(title: Self.searchTitle(title), artist: artist) }
        catch MusicLookupError.noResults { return nil }
        return Self.pickMatch(results, title: title, artist: artist)
    }

    nonisolated static func pickMatch(_ results: [ArtworkMatch], title: String, artist: String) -> ArtworkMatch? {
        let wantedTitle = normalized(searchTitle(title), dropEdition: true)
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

    /// How many requests may run at once per host, and the gap after each.
    nonisolated static func limits(for host: String) -> (concurrent: Int, gap: Double) {
        switch host {
        case "musicbrainz.org": return (1, 1.1)                 // one request a second
        case "www.theaudiodb.com", "theaudiodb.com": return (1, 2.1) // public key: 30 a minute
        case "lrclib.net": return (1, 0.35)
        case "coverartarchive.org", "webservice.fanart.tv": return (3, 0)
        default: return (4, 0)                                  // image hosts (archive.org, r2.theaudiodb.com, assets.fanart.tv)
        }
    }

    private func acquire(_ host: String) async {
        if active[host, default: 0] < Self.limits(for: host).concurrent { active[host, default: 0] += 1; return }
        await withCheckedContinuation { waiting[host, default: []].append($0) }
    }

    private func release(_ host: String) {
        if var queue = waiting[host], !queue.isEmpty {
            let next = queue.removeFirst()
            waiting[host] = queue
            next.resume()                                       // the slot passes straight on
        } else {
            active[host, default: 1] -= 1
        }
    }

    private func fetch(_ url: URL, limit: Int, accept: String? = nil) async throws -> Data {
        let host = url.host ?? ""
        await acquire(host)
        defer { release(host) }
        // LRCLIB in particular answers brief overloads with 503 + "Retry-After: 1".
        // Short waits are retried quietly; long ones go back to the user.
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do { return try await perform(url, limit: limit, accept: accept) }
            catch let error as MusicLookupError {
                guard attempt < Self.maxRetries, let wait = error.retryDelay, wait <= Self.maxAutoRetryWait else { throw error }
                attempt += 1
                // perform() already waits out Retry-After; add a growing pad so retries spread out.
                try await Task.sleep(for: .seconds(0.5 * Double(attempt)))
            }
        }
    }
    private func perform(_ url: URL, limit: Int, accept: String? = nil) async throws -> Data {
        let host = url.host ?? ""
        let delay = (nextRequest[host] ?? .distantPast).timeIntervalSinceNow
        if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
        try Task.checkCancellation()
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(accept ?? (host == "coverartarchive.org" ? "image/*" : "application/json"), forHTTPHeaderField: "Accept")
        // Set the minimum gap even if the request fails.
        let gap = Self.limits(for: host).gap
        defer { if gap > 0 { nextRequest[host] = max(nextRequest[host] ?? .distantPast, Date().addingTimeInterval(gap)) } }
        let (body, response) = try await session.data(for: request)
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
        guard response.expectedContentLength <= Int64(limit), body.count <= limit else { throw MusicLookupError.tooLarge }
        return body
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

// MARK: - Artwork choices for Find Artwork Online

/// Which artwork an image is for.
enum ArtworkKind: String, CaseIterable, Identifiable, Sendable {
    case front, back, disc, booklet
    var id: String { rawValue }
    var label: String {
        switch self {
        case .front: return "Front Cover"
        case .back: return "Back Cover"
        case .disc: return "Disc Art"
        case .booklet: return "Booklet"
        }
    }
    var imageKind: AlbumImageKind? {
        switch self {
        case .front: return nil
        case .back: return .back
        case .disc: return .disc
        case .booklet: return .booklet
        }
    }
}

/// One image Find Artwork Online can offer.
struct ArtCandidate: Identifiable, Sendable, Equatable {
    var id: URL { url }
    let kind: ArtworkKind
    /// Disc number for disc art, page number for booklet pages.
    let disc: Int?
    /// The image to save (up to 1200 pixels where the service offers sizes).
    let url: URL
    /// A smaller image for the picker; the full image is used if it fails.
    let previewURL: URL?
    let source: ArtSource
    /// "2009 · GB", "Disc 2", "12 likes"…
    var note: String = ""
}

extension MusicLookupClient {
    /// Every front, back and disc image found for the album, grouped by kind in a
    /// sensible default order: the Cover Art Archive's chosen release, its other editions
    /// (up to five), then TheAudioDB, then fanart.tv (with a personal key).
    func artCandidates(_ match: ArtworkMatch, fanartKey: String? = nil) async -> [ArtCandidate] {
        async let archive = artCandidates(match, source: .coverArtArchive, fanartKey: fanartKey)
        async let audioDB = artCandidates(match, source: .theAudioDB, fanartKey: fanartKey)
        async let fanart = artCandidates(match, source: .fanartTV, fanartKey: fanartKey)
        var seen = Set<URL>()
        return (await archive + audioDB + fanart).filter { seen.insert($0.url).inserted }
    }

    /// An album title without trailing notes such as "(Deluxe Edition)", "[Remastered]"
    /// or "(declipped)", which MusicBrainz titles don't have.
    nonisolated static func searchTitle(_ title: String) -> String {
        var text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        while let range = text.range(of: #"\s*[\(\[][^\(\)\[\]]*[\)\]]\s*$"#, options: .regularExpression),
              range.lowerBound != text.startIndex {
            text.removeSubrange(range)
        }
        return text
    }

    /// Downloads an image from one of the art services (recent ones come from memory).
    func image(_ url: URL, limit: Int = 25 * 1024 * 1024) async throws -> Data {
        guard url.scheme == "https", Self.safeURL(url.absoluteString) != nil else { throw MusicLookupError.invalidResponse }
        if let cached = imageCache[url] { return cached }
        let data = try await fetch(url, limit: limit, accept: "image/*")
        if imageCache[url] == nil {
            imageCache[url] = data; imageCacheOrder.append(url); imageCacheBytes += data.count
            while imageCacheBytes > 160 * 1024 * 1024, !imageCacheOrder.isEmpty {
                let old = imageCacheOrder.removeFirst()
                imageCacheBytes -= imageCache.removeValue(forKey: old)?.count ?? 0
            }
        }
        return data
    }

    /// One source's images for an album (cached). The Cover Art Archive's other editions
    /// are only looked up when `editions` is true (they matter for back and disc art).
    func artCandidates(_ match: ArtworkMatch, source: ArtSource, editions: Bool = true, fanartKey: String? = nil) async -> [ArtCandidate] {
        let group = match.id.uuidString.lowercased()
        let cacheKey = "\(source.rawValue)|\(group)|\(source == .coverArtArchive && editions)"
        if let cached = candidateCache[cacheKey] { return cached }
        var result: [ArtCandidate] = []
        switch source {
        case .coverArtArchive:
            // The group's own index and the edition list are fetched at the same time.
            let indexURL = URL(string: "https://coverartarchive.org/release-group/\(group)")!
            let browseURL = URL(string: "https://musicbrainz.org/ws/2/release?release-group=\(group)&fmt=json&limit=100")!
            let indexTask = Task { try? await self.fetch(indexURL, limit: 2 * 1024 * 1024, accept: "application/json") }
            let browseTask: Task<Data?, Never>? = editions ? Task { try? await self.fetch(browseURL, limit: 4 * 1024 * 1024) } : nil
            let index = await indexTask.value
            let chosen = index.flatMap { Self.releaseID(inIndex: $0) }
            if let index { result += (try? Self.parseCoverCandidates(index, note: "")) ?? [] }
            if let browse = await browseTask?.value {
                let list = ((try? Self.parseEditions(browse)) ?? []).filter { $0.id != chosen }.prefix(5)
                let found = await withTaskGroup(of: (Int, [ArtCandidate]).self) { group in
                    for (i, edition) in list.enumerated() {
                        group.addTask {
                            let url = URL(string: "https://coverartarchive.org/release/\(edition.id)")!
                            guard let data = try? await self.fetch(url, limit: 2 * 1024 * 1024, accept: "application/json") else { return (i, []) }
                            return (i, (try? Self.parseCoverCandidates(data, note: edition.label)) ?? [])
                        }
                    }
                    var all: [(Int, [ArtCandidate])] = []
                    for await item in group { all.append(item) }
                    return all.sorted { $0.0 < $1.0 }.flatMap { $0.1 }
                }
                result += found
            }
        case .theAudioDB:
            let byGroup = URL(string: "https://www.theaudiodb.com/api/v1/json/\(Self.audioDBKey)/album-mb.php?i=\(group)")!
            result = (try? Self.parseAudioDBCandidates(try await fetch(byGroup, limit: 1024 * 1024))) ?? []
            if result.isEmpty {
                result = (try? Self.parseAudioDBCandidates(try await fetch(Self.audioDBSearchURL(title: match.title, artist: match.artist), limit: 1024 * 1024))) ?? []
            }
        case .fanartTV:
            guard let key = fanartKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty,
                  var parts = URLComponents(string: "https://webservice.fanart.tv/v3/music/albums/\(group)") else { return [] }
            parts.queryItems = [URLQueryItem(name: "api_key", value: key)]
            if let url = parts.url, let data = try? await fetch(url, limit: 1024 * 1024) {
                result = (try? Self.parseFanartCandidates(data, releaseGroup: group)) ?? []
            }
        }
        if !Task.isCancelled { candidateCache[cacheKey] = result }
        return result
    }

    /// The default picks: the first front; a back scan, else any back; disc art as in
    /// mergeExtras (cut-outs unless the archive has scans of more discs), one per disc.
    nonisolated static func defaultChoices(_ candidates: [ArtCandidate]) -> (front: ArtCandidate?, back: ArtCandidate?, discs: [Int: ArtCandidate]) {
        let front = candidates.first { $0.kind == .front }
        let back = candidates.first { $0.kind == .back && $0.source == .coverArtArchive } ?? candidates.first { $0.kind == .back }
        func perDisc(_ list: [ArtCandidate]) -> [Int: ArtCandidate] {
            var result: [Int: ArtCandidate] = [:]
            for item in list where result[item.disc ?? 1] == nil { result[item.disc ?? 1] = item }
            return result
        }
        let discs = candidates.filter { $0.kind == .disc }
        let scans = perDisc(discs.filter { $0.source == .coverArtArchive })
        let fanart = perDisc(discs.filter { $0.source == .fanartTV })
        let cutOuts = fanart.isEmpty ? perDisc(discs.filter { $0.source == .theAudioDB }) : fanart
        return (front, back, !cutOuts.isEmpty && cutOuts.count >= scans.count ? cutOuts : scans)
    }

    nonisolated static func releaseID(inIndex data: Data) -> String? {
        struct Index: Decodable { let release: String? }
        guard let release = (try? JSONDecoder().decode(Index.self, from: data))?.release else { return nil }
        return URL(string: release)?.lastPathComponent.lowercased()
    }

    /// Releases with cover art beyond a lone front, best first, each with a short label.
    nonisolated static func parseEditions(_ data: Data) throws -> [(id: String, label: String)] {
        struct Browse: Decodable { let releases: [Release] }
        struct Release: Decodable {
            let id: String
            let date: String?
            let country: String?
            let disambiguation: String?
        }
        guard let browse = try? JSONDecoder().decode(Browse.self, from: data) else { throw MusicLookupError.invalidResponse }
        let order = try parseReleaseBrowse(data)
        let byID = Dictionary(browse.releases.map { ($0.id.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        return order.map { id in
            let release = byID[id]
            let parts = [String((release?.date ?? "").prefix(4)), release?.country ?? "", release?.disambiguation ?? ""]
                .filter { !$0.isEmpty }
            return (id, parts.isEmpty ? "Other edition" : parts.joined(separator: " · "))
        }
    }

    /// Front, back, disc ("Medium") and booklet images of a Cover Art Archive index.
    nonisolated static func parseCoverCandidates(_ data: Data, note: String) throws -> [ArtCandidate] {
        struct Index: Decodable { let images: [Image] }
        struct Image: Decodable {
            let types: [String]?
            let front: Bool?
            let back: Bool?
            let image: String?
            let thumbnails: [String: String]?
            let comment: String?
        }
        guard let index = try? JSONDecoder().decode(Index.self, from: data) else { throw MusicLookupError.invalidResponse }
        func archiveURL(_ string: String?) -> URL? {
            guard let url = safeURL(string), let host = url.host?.lowercased(),
                  host == "coverartarchive.org" || host == "archive.org" || host.hasSuffix(".archive.org") else { return nil }
            return url
        }
        let discs = (try? parseCoverExtras(data)) ?? []
        var result: [ArtCandidate] = []
        var page = 0
        for image in index.images {
            let types = Set((image.types ?? []).map { $0.lowercased() })
            guard let url = archiveURL(image.thumbnails?["1200"] ?? image.thumbnails?["large"] ?? image.image) else { continue }
            let preview = archiveURL(image.thumbnails?["250"] ?? image.thumbnails?["small"])
            let comment = (image.comment ?? "").trimmingCharacters(in: .whitespaces)
            let label = [note, comment].filter { !$0.isEmpty }.joined(separator: " · ")
            if types.contains("front") || image.front == true {
                result.append(ArtCandidate(kind: .front, disc: nil, url: url, previewURL: preview, source: .coverArtArchive, note: label))
            } else if types.contains("back") || image.back == true {
                result.append(ArtCandidate(kind: .back, disc: nil, url: url, previewURL: preview, source: .coverArtArchive, note: label))
            } else if types.contains("booklet") {
                // Booklet scans are listed in page order.
                page += 1
                result.append(ArtCandidate(kind: .booklet, disc: page, url: url, previewURL: preview, source: .coverArtArchive, note: note.isEmpty ? "Chosen release" : note))
            } else if types.contains("medium") {
                // Numbered the same way as parseCoverExtras.
                let disc = discs.first { $0.kind == .disc && $0.url == url }?.disc ?? 1
                result.append(ArtCandidate(kind: .disc, disc: disc, url: url, previewURL: preview, source: .coverArtArchive, note: label))
            }
        }
        return result
    }

    /// TheAudioDB album: front (HQ first), back and cut-out CD art.
    nonisolated static func parseAudioDBCandidates(_ data: Data) throws -> [ArtCandidate] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MusicLookupError.invalidResponse }
        guard let album = (object["album"] as? [[String: Any]])?.first else { return [] }
        var result: [ArtCandidate] = []
        func add(_ field: String, _ kind: ArtworkKind, _ note: String = "") {
            guard let url = safeURL(album[field] as? String) else { return }
            // TheAudioDB serves a small version at "<image>/small".
            result.append(ArtCandidate(kind: kind, disc: kind == .disc ? 1 : nil, url: url,
                                       previewURL: URL(string: url.absoluteString + "/small"), source: .theAudioDB, note: note))
        }
        add("strAlbumThumbHQ", .front, "High quality")
        add("strAlbumThumb", .front)
        add("strAlbumBack", .back)
        add("strAlbumCDart", .disc)
        return result
    }

    /// fanart.tv album: covers and cut-out disc art, most liked first.
    nonisolated static func parseFanartCandidates(_ data: Data, releaseGroup: String) throws -> [ArtCandidate] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MusicLookupError.invalidResponse }
        let albums = object["albums"] as? [String: Any] ?? [:]
        let album = (albums[releaseGroup] ?? albums.first(where: { $0.key.lowercased() == releaseGroup })?.value) as? [String: Any]
        func int(_ value: Any?) -> Int? { (value as? Int) ?? (value as? String).flatMap { Int($0) } }
        func items(_ field: String, _ kind: ArtworkKind) -> [ArtCandidate] {
            (album?[field] as? [[String: Any]] ?? [])
                .compactMap { item -> (Int, ArtCandidate)? in
                    guard let url = safeURL(item["url"] as? String) else { return nil }
                    let likes = int(item["likes"]) ?? 0
                    // fanart.tv serves previews under /preview/ instead of /fanart/.
                    let preview = URL(string: url.absoluteString.replacingOccurrences(of: "/fanart/", with: "/preview/"))
                    let disc = kind == .disc ? max(1, int(item["disc"]) ?? 1) : nil
                    return (likes, ArtCandidate(kind: kind, disc: disc, url: url, previewURL: preview, source: .fanartTV,
                                                note: likes == 1 ? "1 like" : "\(likes) likes"))
                }
                .sorted { $0.0 > $1.0 }
                .map { $0.1 }
        }
        return items("albumcover", .front) + items("cdart", .disc)
    }
}
