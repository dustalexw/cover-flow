import AVFoundation
import Foundation

struct ParsedMetadata {
    var title: String?
    var artist: String?
    var album: String?
    var albumArtist: String?
    var trackNumber: Int?
    var discNumber: Int?
    var year: Int?
    var genre: String?
    var duration: Double = 0
    var artwork: Data?
    /// True when we had to fall back to the filename/folder for title or album.
    var usedFallback = false
}

enum MetadataError: LocalizedError {
    case notPlayable
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .notPlayable: return "This audio format can’t be played on this device."
        case .unreadable(let why): return why
        }
    }
}

enum MetadataReader {
    /// Formats AVFoundation plays natively on macOS.
    static let supportedExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "m4p", "aac", "adts", "wav", "wave", "aif", "aiff", "aifc", "caf", "flac", "mp4", "3gp", "ac3", "eac3", "amr"
    ]
    /// Audio formats people commonly have that macOS can’t decode — reported, not silently skipped.
    static let knownUnsupported: Set<String> = [
        "ogg", "oga", "opus", "wma", "ape", "wv", "dsf", "dff", "mka", "mid", "midi", "ra", "rm", "spx", "tta", "mpc", "xm", "mod"
    ]

    static func read(_ url: URL) async throws -> ParsedMetadata {
        var meta = ParsedMetadata()
        let asset = AVURLAsset(url: url)
        let playable: Bool
        let duration: CMTime
        do {
            (playable, duration) = try await asset.load(.isPlayable, .duration)
        } catch {
            throw MetadataError.unreadable(error.localizedDescription)
        }
        guard playable else { throw MetadataError.notPlayable }
        meta.duration = duration.seconds.isFinite ? duration.seconds : 0

        var items: [AVMetadataItem] = (try? await asset.load(.commonMetadata)) ?? []
        if let formats = try? await asset.load(.availableMetadataFormats) {
            for format in formats {
                if let more = try? await asset.loadMetadata(for: format) { items += more }
            }
        }
        for item in items {
            await apply(item, to: &meta)
        }

        if url.pathExtension.lowercased() == "flac" {
            FLACReader.read(url, into: &meta)
        }

        // Fallbacks: filename for title and numbering, folder for album, folder image for artwork.
        let parsed = parseFilename(url.deletingPathExtension().lastPathComponent)
        if meta.title == nil { meta.title = parsed.title; meta.usedFallback = true }
        if meta.trackNumber == nil { meta.trackNumber = parsed.track }
        if meta.discNumber == nil { meta.discNumber = parsed.disc }
        if meta.album == nil { meta.usedFallback = true }
        if meta.artwork == nil { meta.artwork = folderArtwork(near: url) }
        return meta
    }

    private static func apply(_ item: AVMetadataItem, to meta: inout ParsedMetadata) async {
        func string() async -> String? {
            if let s = try? await item.load(.stringValue) { return s.nonEmpty }
            if let n = try? await item.load(.numberValue) { return n.stringValue }
            return nil
        }

        if let key = item.commonKey {
            switch key {
            case .commonKeyTitle:
                if meta.title == nil { meta.title = await string() }
            case .commonKeyArtist:
                if meta.artist == nil { meta.artist = await string() }
            case .commonKeyAlbumName:
                if meta.album == nil { meta.album = await string() }
            case .commonKeyArtwork:
                if meta.artwork == nil, let data = try? await item.load(.dataValue), !data.isEmpty { meta.artwork = data }
            case .commonKeyCreationDate:
                if meta.year == nil, let s = await string() { meta.year = parseYear(s) }
            default:
                break
            }
        }

        guard let id = item.identifier else { return }
        switch id {
        case .iTunesMetadataTrackNumber, .iTunesMetadataDiscNumber:
            var value: Int?
            if let data = try? await item.load(.dataValue), data.count >= 4 {
                let b = [UInt8](data)
                value = Int(b[2]) << 8 | Int(b[3])
            } else if let s = await string() {
                value = parseNumberPair(s)
            }
            if let value, value > 0 {
                if id == .iTunesMetadataTrackNumber { if meta.trackNumber == nil { meta.trackNumber = value } }
                else if meta.discNumber == nil { meta.discNumber = value }
            }
        case .id3MetadataTrackNumber:
            if meta.trackNumber == nil, let s = await string() { meta.trackNumber = parseNumberPair(s) }
        case .id3MetadataPartOfASet:
            if meta.discNumber == nil, let s = await string() { meta.discNumber = parseNumberPair(s) }
        case .iTunesMetadataAlbumArtist, .id3MetadataBand:
            if meta.albumArtist == nil { meta.albumArtist = await string() }
        case .iTunesMetadataUserGenre, .id3MetadataContentType, .quickTimeMetadataGenre:
            if meta.genre == nil, let s = await string() {
                let cleaned = s.replacingOccurrences(of: #"^\(\d+\)"#, with: "", options: .regularExpression).nonEmpty
                if let cleaned, Int(cleaned) == nil { meta.genre = cleaned }
            }
        case .iTunesMetadataReleaseDate, .id3MetadataYear, .id3MetadataRecordingTime, .quickTimeMetadataYear, .id3MetadataReleaseTime:
            if meta.year == nil, let s = await string() { meta.year = parseYear(s) }
        default:
            break
        }
    }

    static func parseNumberPair(_ s: String) -> Int? {
        let first = s.split(separator: "/").first.map(String.init) ?? s
        return Int(first.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil }
    }

    static func parseYear(_ s: String) -> Int? {
        guard let r = s.range(of: #"(1[89]|20)\d\d"#, options: .regularExpression) else { return nil }
        return Int(s[r])
    }

    private static let filenamePattern = try! NSRegularExpression(
        pattern: #"^\s*(?:(\d{1,2})[-.](?=\d))?(\d{1,3})\s*(?:[.\-_)]\s*|\s+)(.+)$"#)

    static func parseFilename(_ name: String) -> (disc: Int?, track: Int?, title: String) {
        let ns = name as NSString
        guard let m = filenamePattern.firstMatch(in: name, range: NSRange(location: 0, length: ns.length)) else {
            return (nil, nil, name)
        }
        func group(_ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        let title = group(3)?.nonEmpty ?? name
        return (group(1).flatMap { Int($0) }, group(2).flatMap { Int($0) }, title)
    }

    static func folderArtwork(near url: URL) -> Data? {
        let dir = url.deletingLastPathComponent()
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        let names = ["cover", "folder", "front", "album", "artwork", "albumart"]
        let exts = ["jpg", "jpeg", "png", "heic", "webp", "tif", "tiff"]
        let match = files.first { f in
            let lower = f.lowercased()
            let base = (lower as NSString).deletingPathExtension
            let ext = (lower as NSString).pathExtension
            return names.contains(base) && exts.contains(ext)
        }
        guard let match else { return nil }
        return try? Data(contentsOf: dir.appendingPathComponent(match))
    }
}

/// Minimal FLAC reader for Vorbis comments and embedded pictures, which AVFoundation doesn't surface.
enum FLACReader {
    static func read(_ url: URL, into meta: inout ParsedMetadata) {
        guard let h = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? h.close() }
        guard let magic = try? h.read(upToCount: 4), magic == Data("fLaC".utf8) else { return }
        var isLast = false
        var blocks = 0
        while !isLast && blocks < 64 {
            blocks += 1
            guard let hdr = try? h.read(upToCount: 4), hdr.count == 4 else { return }
            let b = [UInt8](hdr)
            isLast = (b[0] & 0x80) != 0
            let type = b[0] & 0x7F
            let length = Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
            if type == 4 || (type == 6 && meta.artwork == nil) {
                guard let body = try? h.read(upToCount: length), body.count == length else { return }
                let bytes = [UInt8](body)
                if type == 4 { parseVorbis(bytes, into: &meta) } else { parsePicture(bytes, into: &meta) }
            } else {
                guard let offset = try? h.offset() else { return }
                do { try h.seek(toOffset: offset + UInt64(length)) } catch { return }
            }
        }
    }

    private static func le32(_ b: [UInt8], _ i: Int) -> Int? {
        guard i + 4 <= b.count else { return nil }
        return Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24
    }

    private static func be32(_ b: [UInt8], _ i: Int) -> Int? {
        guard i + 4 <= b.count else { return nil }
        return Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
    }

    private static func parseVorbis(_ b: [UInt8], into meta: inout ParsedMetadata) {
        var i = 0
        guard let vendorLen = le32(b, i) else { return }
        i += 4 + vendorLen
        guard let count = le32(b, i) else { return }
        i += 4
        for _ in 0..<min(count, 1000) {
            guard let len = le32(b, i), i + 4 + len <= b.count else { return }
            let s = String(decoding: b[(i + 4)..<(i + 4 + len)], as: UTF8.self)
            i += 4 + len
            guard let eq = s.firstIndex(of: "=") else { continue }
            let key = s[..<eq].uppercased()
            let value = String(s[s.index(after: eq)...]).nonEmpty
            guard let value else { continue }
            switch key {
            case "TITLE": if meta.title == nil { meta.title = value }
            case "ARTIST": if meta.artist == nil { meta.artist = value }
            case "ALBUM": if meta.album == nil { meta.album = value }
            case "ALBUMARTIST", "ALBUM ARTIST", "ALBUM_ARTIST": if meta.albumArtist == nil { meta.albumArtist = value }
            case "TRACKNUMBER": if meta.trackNumber == nil { meta.trackNumber = MetadataReader.parseNumberPair(value) }
            case "DISCNUMBER": if meta.discNumber == nil { meta.discNumber = MetadataReader.parseNumberPair(value) }
            case "DATE", "YEAR", "ORIGINALDATE": if meta.year == nil { meta.year = MetadataReader.parseYear(value) }
            case "GENRE": if meta.genre == nil { meta.genre = value }
            default: break
            }
        }
    }

    private static func parsePicture(_ b: [UInt8], into meta: inout ParsedMetadata) {
        var i = 4 // picture type
        guard let mimeLen = be32(b, i) else { return }
        i += 4 + mimeLen
        guard let descLen = be32(b, i) else { return }
        i += 4 + descLen + 16
        guard let dataLen = be32(b, i), i + 4 + dataLen <= b.count, dataLen > 0 else { return }
        meta.artwork = Data(b[(i + 4)..<(i + 4 + dataLen)])
    }
}
