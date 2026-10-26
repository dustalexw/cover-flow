import Foundation

enum AudioStem: String, Codable, CaseIterable, Identifiable, Sendable {
    case vocals, drums, bass, guitar, piano, other, instrumental
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .vocals: return "mic.fill"
        case .drums: return "circle.grid.2x2.fill"
        case .bass: return "waveform.path"
        case .guitar: return "guitars.fill"
        case .piano: return "pianokeys"
        case .other: return "music.note.list"
        case .instrumental: return "mic.slash.fill"
        }
    }
}

enum KaraokePlayback: String, CaseIterable, Identifiable {
    case original, instrumental, vocals, drums, bass, guitar, piano, other, mix
    var id: String { rawValue }
    var stem: AudioStem? { AudioStem(rawValue: rawValue) }
    var title: String {
        switch self {
        case .original: return "Original"
        case .instrumental: return "Karaoke"
        case .mix: return "Stem Mix"
        default: return stem?.title ?? rawValue.capitalized
        }
    }
}

struct StemMixSettings: Equatable, Sendable {
    var levels: [AudioStem: Float] = [:]
    var muted: Set<AudioStem> = []
    var solo: Set<AudioStem> = []
    func gain(_ stem: AudioStem) -> Float {
        guard !muted.contains(stem), solo.isEmpty || solo.contains(stem) else { return 0 }
        let level = levels[stem] ?? 1
        return level.isFinite ? min(1, max(0, level)) : 0
    }
}
