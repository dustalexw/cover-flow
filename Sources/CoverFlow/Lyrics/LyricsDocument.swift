import Foundation

struct LyricCue: Identifiable, Equatable, Sendable {
    let id: Int
    let time: Double
    let text: String
    /// Word timings from enhanced LRC (`<mm:ss.xx>word`), when the line has them.
    var words: [LyricWord] = []
}

/// One timed word of an enhanced LRC line; `text` keeps its trailing space.
struct LyricWord: Equatable, Sendable {
    let time: Double
    let text: String
}

/// Simple LRC with repeated timestamps, translations, metadata and millisecond offsets.
/// A positive LRC offset advances the lyric display relative to the audio.
struct LyricsDocument: Equatable, Sendable {
    let cues: [LyricCue]
    let plainText: String
    let offset: Double
    var isSynced: Bool { !cues.isEmpty }
    var isEmpty: Bool { cues.isEmpty && plainText.isEmpty }

    static func parse(_ input: String) -> LyricsDocument {
        let timestamp = try! NSRegularExpression(pattern: #"\[(\d+):(\d{1,2})(?:[.:](\d{1,3}))?\]"#)
        let metadata = try! NSRegularExpression(pattern: #"^\[([A-Za-z]+):(.*)\]$"#)
        let wordTimestamp = try! NSRegularExpression(pattern: #"<(\d+):(\d{1,2})(?:[.:](\d{1,3}))?>"#)
        var entries: [(time: Double, text: String, words: [LyricWord], order: Int)] = []
        var plain: [String] = []
        var offset = 0.0
        for raw in input.replacingOccurrences(of: "\u{FEFF}", with: "").components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let range = NSRange(line.startIndex..., in: line)
            if let tag = metadata.firstMatch(in: line, range: range),
               let name = Range(tag.range(at: 1), in: line), let value = Range(tag.range(at: 2), in: line) {
                if line[name].lowercased() == "offset", let milliseconds = Double(line[value]), milliseconds.isFinite {
                    offset = milliseconds / 1000
                }
                continue
            }
            // Only leading timestamps belong to the line. Brackets in the lyric
            // itself are text, not another timestamp or metadata tag.
            var times: [Double] = []
            var end = 0
            for match in timestamp.matches(in: line, range: range) {
                let gap = (line as NSString).substring(with: NSRange(location: end, length: match.range.location - end))
                guard gap.trimmingCharacters(in: .whitespaces).isEmpty else { break }
                end = NSMaxRange(match.range)
                let ns = line as NSString
                guard let minutes = Double(ns.substring(with: match.range(at: 1))),
                      let seconds = Double(ns.substring(with: match.range(at: 2))), seconds < 60 else { continue }
                let fraction = match.range(at: 3).location == NSNotFound ? 0
                    : Double("0." + ns.substring(with: match.range(at: 3))) ?? 0
                let time = minutes * 60 + seconds + fraction
                if time.isFinite { times.append(time) }
            }
            if !times.isEmpty {
                let remaining = (line as NSString).substring(from: end).trimmingCharacters(in: .whitespaces)
                let text = wordTimestamp.stringByReplacingMatches(in: remaining,
                    range: NSRange(remaining.startIndex..., in: remaining), withTemplate: "")
                let words = Self.words(in: remaining, pattern: wordTimestamp)
                for time in times {
                    // A line repeated at several times only keeps word timings for its first time.
                    entries.append((time, text, time == times[0] ? words : [], entries.count))
                }
            } else if line.isEmpty || !line.hasPrefix("[") {
                plain.append(line)
            }
        }
        entries.sort { $0.time == $1.time ? $0.order < $1.order : $0.time < $1.time }
        var cues: [LyricCue] = []
        for entry in entries {
            if let previous = cues.last, previous.time == entry.time {
                // Two lines at the same timestamp often represent a translation.
                var texts = previous.text.components(separatedBy: "\n").filter { !$0.isEmpty }
                if !entry.text.isEmpty && !texts.contains(entry.text) { texts.append(entry.text) }
                cues[cues.count - 1] = LyricCue(id: previous.id, time: previous.time,
                                               text: texts.joined(separator: "\n"),
                                               words: previous.words.isEmpty ? entry.words : previous.words)
            } else {
                cues.append(LyricCue(id: cues.count, time: entry.time, text: entry.text, words: entry.words))
            }
        }
        return LyricsDocument(cues: cues, plainText: plain.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines), offset: offset)
    }

    /// Timed words of an enhanced LRC line: each `<mm:ss.xx>` tag starts a word that
    /// runs to the next tag. Text before the first tag is dropped from the timing.
    private static func words(in line: String, pattern: NSRegularExpression) -> [LyricWord] {
        let ns = line as NSString
        let matches = pattern.matches(in: line, range: NSRange(location: 0, length: ns.length))
        var words: [LyricWord] = []
        for (i, match) in matches.enumerated() {
            guard let minutes = Double(ns.substring(with: match.range(at: 1))),
                  let seconds = Double(ns.substring(with: match.range(at: 2))), seconds < 60 else { continue }
            let fraction = match.range(at: 3).location == NSNotFound ? 0 : Double("0." + ns.substring(with: match.range(at: 3))) ?? 0
            let start = NSMaxRange(match.range)
            let end = i + 1 < matches.count ? matches[i + 1].range.location : ns.length
            let text = ns.substring(with: NSRange(location: start, length: end - start))
            guard !text.isEmpty else { continue }
            words.append(LyricWord(time: minutes * 60 + seconds + fraction, text: text))
        }
        return words
    }

    /// The word being sung in a cue, by its word timings.
    func activeWord(in cue: LyricCue, at playbackTime: Double) -> Int? {
        guard !cue.words.isEmpty, playbackTime.isFinite else { return nil }
        let time = playbackTime + offset
        return cue.words.lastIndex { $0.time <= time }
    }

    func activeIndex(at playbackTime: Double) -> Int? {
        guard playbackTime.isFinite else { return nil }
        let time = playbackTime + offset
        var low = 0, high = cues.count
        while low < high {
            let middle = (low + high) / 2
            if cues[middle].time <= time { low = middle + 1 } else { high = middle }
        }
        return low == 0 ? nil : low - 1
    }

    func playbackTime(for cue: LyricCue) -> Double { max(0, cue.time - offset) }
}
