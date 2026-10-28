import Foundation

/// Opus in Ogg (RFC 7845): page and packet access for the tag reader and the decoder.
/// Nothing here decodes audio; `PCMDecoder` hands the packets to Core Audio.
enum OggOpusError: LocalizedError, Equatable {
    case notOpus
    case unsupportedChannels(Int)
    case decoderUnavailable
    case damaged

    var errorDescription: String? {
        switch self {
        case .notOpus: return "This Ogg file doesn’t contain Opus audio."
        case .unsupportedChannels(let count): return "Opus audio with \(count) channels can’t be played; mono and stereo can."
        case .decoderUnavailable: return "Opus audio can’t be decoded on this device."
        case .damaged: return "The Opus file is damaged."
        }
    }
}

/// The identification header that starts every Opus stream.
struct OpusHead: Equatable {
    let channels: Int
    /// Decoded samples at the start that are encoder delay, not audio.
    let preSkip: Int
    let inputSampleRate: Int
    /// Q7.8 dB gain that players apply to every decoded sample.
    let outputGain: Int16
    let mappingFamily: Int

    init?(_ p: [UInt8]) {
        guard p.count >= 19, p.starts(with: Array("OpusHead".utf8)), p[8] >> 4 == 0, p[9] > 0 else { return nil }
        channels = Int(p[9])
        preSkip = Int(p[10]) | Int(p[11]) << 8
        inputSampleRate = Int(p[12]) | Int(p[13]) << 8 | Int(p[14]) << 16 | Int(p[15]) << 24
        outputGain = Int16(bitPattern: UInt16(p[16]) | UInt16(p[17]) << 8)
        mappingFamily = Int(p[18])
    }

    var linearGain: Float { Float(pow(10, Double(outputGain) / (20 * 256))) }
}

enum OpusPacket {
    /// Opus always decodes at 48 kHz; granule positions count samples at this rate.
    static let sampleRate = 48_000

    /// Samples per channel coded by a packet, from its table-of-contents byte (RFC 6716, 3.1).
    static func sampleCount(_ packet: [UInt8]) -> Int? {
        guard let toc = packet.first else { return nil }
        let config = Int(toc >> 3)
        let frameSize: Int
        switch config {
        case 0..<12: frameSize = [480, 960, 1_920, 2_880][config & 3]   // SILK: 10–60 ms
        case 12..<16: frameSize = [480, 960][config & 1]               // Hybrid: 10–20 ms
        default: frameSize = [120, 240, 480, 960][config & 3]          // CELT: 2.5–20 ms
        }
        let frames: Int
        switch toc & 3 {
        case 0: frames = 1
        case 1, 2: frames = 2
        default:
            guard packet.count >= 2 else { return nil }
            frames = Int(packet[1] & 0x3F)
        }
        let samples = frames * frameSize
        return samples > 0 && samples <= 5_760 ? samples : nil
    }
}

/// The first Opus stream in an Ogg file. The file is memory-mapped, so opening even a
/// long recording only touches page headers and the two header packets.
final class OggOpusStream {
    struct Page {
        let bodyOffset: Int
        let segments: [UInt8]
        /// Position after the last packet that ends on this page; -1 when none does.
        let granule: Int64
    }

    /// Where the next packet starts: a lacing segment on a page.
    struct Cursor: Equatable {
        var page: Int
        var segment: Int
        var offset: Int
    }

    let head: OpusHead
    /// The OpusTags packet without its signature: a Vorbis comment block.
    let comments: [UInt8]
    let pages: [Page]
    /// The first audio packet, after the two header packets.
    let audioStart: Cursor
    /// Granule position of the first sample of the first audio packet.
    let startGranule: Int64
    /// Granule position of the first sample to play; earlier samples are pre-skip.
    let origin: Int64
    /// Granule position after the last sample to play.
    let endGranule: Int64
    private let data: Data

    /// Samples per channel to play, at 48 kHz.
    var length: Int64 { max(0, endGranule - origin) }
    var duration: Double { Double(length) / Double(OpusPacket.sampleRate) }

    static func isOgg(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)) == Data("OggS".utf8)
    }

    convenience init(url: URL, readComments: Bool = true) throws {
        try self.init(data: Data(contentsOf: url, options: .alwaysMapped), readComments: readComments)
    }

    init(data: Data, readComments: Bool = true) throws {
        self.data = data
        let all = Self.scanPages(data)
        // An Ogg file can multiplex streams; use the first whose first packet is OpusHead.
        guard let first = all.first(where: { $0.isFirst && Self.body(of: $0, in: data).starts(with: Array("OpusHead".utf8)) }) else {
            throw OggOpusError.notOpus
        }
        var pages: [Page] = []
        for page in all where page.serial == first.serial {
            pages.append(Page(bodyOffset: page.bodyOffset, segments: page.segments, granule: page.granule))
            if page.isLast { break }
        }
        self.pages = pages

        var reader = PacketReader(pages: pages, data: data, cursor: Cursor(page: 0, segment: 0, offset: pages[0].bodyOffset))
        guard let headPacket = reader.next(), let head = OpusHead(headPacket) else { throw OggOpusError.notOpus }
        // Family 0 is mono or stereo. Other families carry surround channel mappings.
        guard head.mappingFamily == 0, head.channels <= 2 else { throw OggOpusError.unsupportedChannels(head.channels) }
        self.head = head
        guard let tags = reader.next(retainingPayload: readComments) else { throw OggOpusError.damaged }
        comments = tags.starts(with: Array("OpusTags".utf8)) ? Array(tags.dropFirst(8)) : []
        reader.normalize()
        let audioStart = reader.cursor
        self.audioStart = audioStart

        // A page's granule position counts every sample up to its last complete packet,
        // so the stream's start follows from the first such page and its packets.
        guard let firstTimed = pages.indices.first(where: { $0 >= audioStart.page && pages[$0].granule >= 0 }),
              let lastTimed = pages.indices.last(where: { pages[$0].granule >= 0 }) else {
            throw OggOpusError.damaged
        }
        var counted: Int64 = 0
        while let packet = reader.next(), reader.cursor.page <= firstTimed {
            guard let samples = OpusPacket.sampleCount(packet) else { throw OggOpusError.damaged }
            counted += Int64(samples)
        }
        // On a stream's only timed page, a position below the packets' total trims the end.
        let start = pages[firstTimed].granule - counted
        startGranule = firstTimed == lastTimed && start < 0 ? 0 : start
        origin = max(startGranule, Int64(head.preSkip))
        endGranule = pages[lastTimed].granule
    }

    /// Packets from the start of the audio.
    func packets() -> PacketReader {
        PacketReader(pages: pages, data: data, cursor: audioStart)
    }

    /// A reader that starts at least `preroll` samples before `granule`, as the decoder
    /// needs that much audio to converge (RFC 7845, 4.6), and the position of its first sample.
    func packets(toReach granule: Int64, preroll: Int64 = 3_840) -> (reader: PacketReader, position: Int64) {
        let limit = granule - preroll
        // Skip the packets that end on the chosen page; the next one starts at its granule position.
        guard limit > startGranule,
              let index = pages.indices.last(where: { $0 >= audioStart.page && pages[$0].granule >= 0 && pages[$0].granule <= limit }),
              let last = pages[index].segments.lastIndex(where: { $0 < 255 }) else {
            return (packets(), startGranule)
        }
        let page = pages[index]
        let offset = page.bodyOffset + page.segments[...last].reduce(0) { $0 + Int($1) }
        var reader = PacketReader(pages: pages, data: data, cursor: Cursor(page: index, segment: last + 1, offset: offset))
        reader.normalize()
        return (reader, page.granule)
    }

    struct PacketReader {
        fileprivate let pages: [Page]
        fileprivate let data: Data
        /// After `next()`, the page holds the packet's last segment.
        private(set) var cursor: Cursor

        fileprivate init(pages: [Page], data: Data, cursor: Cursor) {
            self.pages = pages
            self.data = data
            self.cursor = cursor
        }

        /// The next complete packet. A packet cut off by the end of the file is dropped.
        mutating func next(retainingPayload: Bool = true) -> [UInt8]? {
            var packet: [UInt8] = []
            return next(into: &packet, retainingPayload: retainingPayload) ? packet : nil
        }

        /// Reuse packet storage for audio; large comment packets can be traversed
        /// from their lacing table without copying or touching their payload.
        mutating func next(into packet: inout [UInt8], retainingPayload: Bool = true) -> Bool {
            packet.removeAll(keepingCapacity: true)
            while cursor.page < pages.count {
                let page = pages[cursor.page]
                guard cursor.segment < page.segments.count else {
                    cursor.page += 1
                    cursor.segment = 0
                    if cursor.page < pages.count { cursor.offset = pages[cursor.page].bodyOffset }
                    continue
                }
                let length = Int(page.segments[cursor.segment])
                guard cursor.offset + length <= data.count else { return false }
                if retainingPayload { packet.append(contentsOf: data[cursor.offset..<(cursor.offset + length)]) }
                cursor.segment += 1
                cursor.offset += length
                if length < 255 { return true }
            }
            return false
        }

        /// Moves a cursor left at the end of a page to the start of the next one.
        fileprivate mutating func normalize() {
            while cursor.page < pages.count && cursor.segment >= pages[cursor.page].segments.count {
                cursor.page += 1
                cursor.segment = 0
                if cursor.page < pages.count { cursor.offset = pages[cursor.page].bodyOffset }
            }
        }
    }

    private struct RawPage {
        let flags: UInt8
        let granule: Int64
        let serial: UInt32
        let segments: [UInt8]
        let bodyOffset: Int
        var isFirst: Bool { flags & 0x02 != 0 }
        var isLast: Bool { flags & 0x04 != 0 }
    }

    private static func body(of page: RawPage, in data: Data) -> [UInt8] {
        let size = page.segments.reduce(0) { $0 + Int($1) }
        return [UInt8](data[page.bodyOffset..<min(data.count, page.bodyOffset + size)])
    }

    private static let capture = Data("OggS".utf8)

    /// Page headers in file order. Damaged bytes between pages are skipped by searching
    /// for the next capture pattern; a page cut off by the end of the file ends the scan.
    private static func scanPages(_ data: Data) -> [RawPage] {
        var pages: [RawPage] = []
        var i = 0
        while i + 27 <= data.count {
            guard data[i] == 0x4F, data[i + 1] == 0x67, data[i + 2] == 0x67, data[i + 3] == 0x53, data[i + 4] == 0 else {
                guard let next = data.range(of: capture, in: (i + 1)..<data.count) else { break }
                i = next.lowerBound
                continue
            }
            var granule: UInt64 = 0
            for k in 0..<8 { granule |= UInt64(data[i + 6 + k]) << (8 * UInt64(k)) }
            var serial: UInt32 = 0
            for k in 0..<4 { serial |= UInt32(data[i + 14 + k]) << (8 * UInt32(k)) }
            let count = Int(data[i + 26])
            guard i + 27 + count <= data.count else { break }
            let segments = [UInt8](data[(i + 27)..<(i + 27 + count)])
            let bodyOffset = i + 27 + count
            let size = segments.reduce(0) { $0 + Int($1) }
            guard bodyOffset + size <= data.count else { break }
            pages.append(RawPage(flags: data[i + 5], granule: Int64(bitPattern: granule), serial: serial,
                                 segments: segments, bodyOffset: bodyOffset))
            i = bodyOffset + size
        }
        return pages
    }
}
