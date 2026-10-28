import AVFoundation
import Foundation

struct ParsedMetadata: Sendable {
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
    /// Formats AVFoundation plays natively, plus Opus in Ogg, which `PCMDecoder` demuxes
    /// itself. On the Mac, the bundled FFmpeg build adds Vorbis, Monkey's Audio, WavPack,
    /// WMA, DSD and the other formats in `FFmpegAudioFile.extensions`.
    static let supportedExtensions: Set<String> = {
        var formats: Set<String> = [
            "mp3", "m4a", "m4b", "m4p", "aac", "adts", "wav", "wave", "aif", "aiff", "aifc", "caf", "flac", "mp4", "3gp", "ac3", "eac3", "amr",
            "opus", "ogg", "oga"
        ]
        #if canImport(CFFmpegAudio)
        formats.formUnion(FFmpegAudioFile.extensions)
        #endif
        return formats
    }()
    /// Audio formats people commonly have that can’t be decoded here — reported, not silently skipped.
    static let knownUnsupported: Set<String> = Set([
        "wma", "ape", "wv", "dsf", "dff", "mka", "weba", "spx", "tta", "tak", "shn", "mpc", "w64",
        "mid", "midi", "ra", "rm", "xm", "mod"
    ]).subtracting(supportedExtensions)

    static func read(_ url: URL) async throws -> ParsedMetadata {
        let cancellation = PlaybackCancellation()
        return try await withTaskCancellationHandler {
            do {
                return try await MetadataIngestionWorker.shared.read(url, cancellation: cancellation)
            } catch {
                try cancellation.check()
                throw error
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    /// AVFoundation can’t open Ogg, so Opus tags and duration come from the stream headers.
    /// Returns nil for another Ogg codec, or for surround Opus when FFmpeg can downmix it.
    fileprivate static func readOggOpus(_ url: URL) throws -> ParsedMetadata? {
        let stream: OggOpusStream
        do {
            stream = try OggOpusStream(url: url)
        } catch OggOpusError.notOpus {
            return nil
        } catch OggOpusError.unsupportedChannels {
            if usesFFmpeg(url, isOgg: true) { return nil }
            throw MetadataError.notPlayable
        } catch {
            throw MetadataError.unreadable(error.localizedDescription)
        }
        var meta = ParsedMetadata()
        meta.duration = stream.duration
        VorbisComments.apply(stream.comments, to: &meta, readsPictures: true)
        return meta
    }

    fileprivate static func usesFFmpeg(_ url: URL, isOgg: Bool) -> Bool {
        #if canImport(CFFmpegAudio)
        return isOgg || FFmpegAudioFile.extensions.contains(url.pathExtension.lowercased())
        #else
        return false
        #endif
    }

    fileprivate static func readFFmpeg(_ url: URL, cancellation: PlaybackCancellation) throws -> ParsedMetadata {
        #if canImport(CFFmpegAudio)
        let file: FFmpegAudioFile
        do {
            file = try FFmpegAudioFile(url: url, cancellation: cancellation)
        } catch {
            try cancellation.check()
            throw MetadataError.unreadable(error.localizedDescription)
        }
        guard file.length > 0 else { throw MetadataError.unreadable("The file contains no audio.") }
        var meta = ParsedMetadata()
        meta.duration = file.duration
        // FFmpeg normalizes common tag names; the alternatives cover APE and WMA spellings.
        meta.title = file.tag("title")
        meta.artist = file.tag("artist")
        meta.album = file.tag("album")
        meta.albumArtist = file.tag("album_artist", "albumartist", "album artist", "WM/AlbumArtist")
        meta.trackNumber = file.tag("track", "tracknumber", "WM/TrackNumber").flatMap(parseNumberPair)
        meta.discNumber = file.tag("disc", "discnumber", "WM/PartOfSet").flatMap(parseNumberPair)
        meta.year = file.tag("date", "year", "originaldate", "WM/Year").flatMap(parseYear)
        meta.genre = file.tag("genre", "WM/Genre")
        meta.artwork = file.picture
        return meta
        #else
        throw MetadataError.notPlayable
        #endif
    }

    fileprivate static func readAsset(_ url: URL) async throws -> ParsedMetadata {
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
                if type == 4 { VorbisComments.apply(bytes, to: &meta) }
                else if let picture = VorbisComments.picture(bytes) { meta.artwork = picture.data }
            } else {
                guard let offset = try? h.offset() else { return }
                do { try h.seek(toOffset: offset + UInt64(length)) } catch { return }
            }
        }
    }
}

/// Vorbis comment blocks, the tags of both FLAC and Opus files.
enum VorbisComments {
    private static func le32(_ b: [UInt8], _ i: Int) -> Int? {
        guard i >= 0, i + 4 <= b.count else { return nil }
        return Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24
    }

    private static func be32(_ b: [UInt8], _ i: Int) -> Int? {
        guard i >= 0, i + 4 <= b.count else { return nil }
        return Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
    }

    /// Fills unset fields. Opus has no picture block, so its cover art is a base64 FLAC
    /// picture in a METADATA_BLOCK_PICTURE comment; `readsPictures` reads those too,
    /// preferring the front cover.
    static func apply(_ b: [UInt8], to meta: inout ParsedMetadata, readsPictures: Bool = false) {
        var i = 0
        guard let vendorLen = le32(b, i) else { return }
        i += 4 + vendorLen
        guard let count = le32(b, i) else { return }
        i += 4
        var hasFrontCover = false
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
            case "METADATA_BLOCK_PICTURE" where readsPictures && !hasFrontCover:
                guard let block = Data(base64Encoded: value, options: .ignoreUnknownCharacters),
                      let image = picture([UInt8](block)) else { continue }
                if image.type == 3 || meta.artwork == nil {
                    meta.artwork = image.data
                    hasFrontCover = image.type == 3
                }
            default: break
            }
        }
    }

    /// A FLAC picture block: its picture type (3 is the front cover) and image data.
    static func picture(_ b: [UInt8]) -> (type: Int, data: Data)? {
        guard let type = be32(b, 0) else { return nil }
        var i = 4
        guard let mimeLen = be32(b, i) else { return nil }
        i += 4 + mimeLen
        guard let descLen = be32(b, i) else { return nil }
        i += 4 + descLen + 16
        guard let dataLen = be32(b, i), dataLen > 0, i + 4 + dataLen <= b.count else { return nil }
        return (type, Data(b[(i + 4)..<(i + 4 + dataLen)]))
    }
}

/// Synchronous tag and folder-art I/O never runs on the UI or playback actor.
/// Serializes heavy imports while allowing asynchronous AVAsset reads to suspend.
private actor MetadataIngestionWorker {
    static let shared = MetadataIngestionWorker()
    func read(_ url: URL, cancellation: PlaybackCancellation) async throws -> ParsedMetadata {
        try cancellation.check()
        var meta: ParsedMetadata
        let isOgg = OggOpusStream.isOgg(url)
        if isOgg, let opus = try MetadataReader.readOggOpus(url) {
            meta = opus
        } else if MetadataReader.usesFFmpeg(url, isOgg: isOgg) {
            meta = try MetadataReader.readFFmpeg(url, cancellation: cancellation)
        } else if isOgg {
            throw MetadataError.notPlayable
        } else {
            meta = try await MetadataReader.readAsset(url)
        }

        try cancellation.check()
        // Fallbacks: filename for title and numbering, folder for album, folder image for artwork.
        let parsed = MetadataReader.parseFilename(url.deletingPathExtension().lastPathComponent)
        if meta.title == nil { meta.title = parsed.title; meta.usedFallback = true }
        if meta.trackNumber == nil { meta.trackNumber = parsed.track }
        if meta.discNumber == nil { meta.discNumber = parsed.disc }
        if meta.album == nil { meta.usedFallback = true }
        if meta.artwork == nil { meta.artwork = MetadataReader.folderArtwork(near: url) }
        try cancellation.check()
        return meta
    }
}
