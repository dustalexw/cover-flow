import Foundation

struct ScrobbleRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let username: String
    let artist: String
    let title: String
    let album: String
    let albumArtist: String?
    let trackNumber: Int?
    let duration: Double
    let timestamp: Int

    var parameters: [String: String] {
        var p = ["artist": artist, "track": title, "album": album, "duration": String(Int(duration)), "timestamp": String(timestamp)]
        if let albumArtist, !albumArtist.isEmpty { p["albumArtist"] = albumArtist }
        if let trackNumber { p["trackNumber"] = String(trackNumber) }
        return p
    }
}

/// Media progress measures listening, while the monotonic clock bounds credit.
/// Explicit seeks rebase the position; paused/buffering time never earns credit.
struct ScrobbleProgress {
    private(set) var listened: Double = 0
    private(set) var submitted = false
    private(set) var timestamp: Int?
    private var position: Double
    private var uptime: Double
    private var playing = false
    var duration: Double

    init(duration: Double, position: Double, uptime: Double) {
        self.duration = duration
        self.position = position
        self.uptime = uptime
    }

    mutating func update(position: Double, playing: Bool, uptime: Double, unixTime: Double) {
        if self.playing {
            let movement = max(0, position - self.position)
            listened += min(movement, max(0, uptime - self.uptime) + 0.1)
        }
        if playing && timestamp == nil { timestamp = Int(unixTime) }
        self.position = position
        self.uptime = uptime
        self.playing = playing
    }

    mutating func seek(to position: Double, uptime: Double) {
        self.position = position
        self.uptime = uptime
    }

    mutating func claimScrobble() -> Bool {
        guard !submitted, timestamp != nil, duration.isFinite, duration > 30,
              listened >= min(duration / 2, 240) else { return false }
        submitted = true
        return true
    }
}
