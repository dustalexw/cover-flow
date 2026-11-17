import Foundation

/// One word of a synced line. `text` keeps its trailing space, so joining the words
/// gives the line back. `start` is nil until the word is timed.
struct LyricsDraftWord: Equatable, Sendable {
  var text: String
  var start: Double?
}

/// A synced line being edited. `start` is nil until the line is timed.
struct LyricsDraftLine: Identifiable, Equatable, Sendable {
  let id: UUID
  var text: String
  var start: Double?
  var words: [LyricsDraftWord]

  init(id: UUID = UUID(), text: String, start: Double? = nil, words: [LyricsDraftWord] = []) {
    self.id = id
    self.text = text
    self.start = start
    self.words = words
  }

  var hasWordTimings: Bool { words.contains { $0.start != nil } }
}

/// Something worth fixing before saving, like Lyripass's lyric checks.
struct LyricsProblem: Equatable, Sendable, Identifiable {
  enum Severity: Equatable, Sendable { case warning, error }
  var line: Int?
  var severity: Severity
  var message: String
  var id: String { "\(line ?? -1)|\(message)" }
}

/// Lyrics being edited, the way Lyripass (LRCGET) edits them: plain text, and lines
/// synced to the music, optionally word by word. Reads and writes LRC, including
/// enhanced LRC word timings (`[00:12.34]<00:12.34>Word <00:12.80>next`).
struct LyricsDraft: Equatable, Sendable {
  static let instrumentalTag = "[au: instrumental]"
  var lines: [LyricsDraftLine] = []
  var plain: String = ""
  var instrumental = false
  /// The file's `[offset:]` in milliseconds, kept as it was.
  var offsetMilliseconds: Int = 0
  /// Header tags such as `[ti:…]` and `[ar:…]`, kept in order.
  var tags: [String] = []

  var isSynced: Bool { lines.contains { $0.start != nil } }
  var isEmpty: Bool { !instrumental && lines.allSatisfy { $0.text.isEmpty } && plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  var unsyncedCount: Int { lines.filter { $0.start == nil }.count }

  // MARK: Reading

  static func parse(_ input: String) -> LyricsDraft {
    var draft = LyricsDraft()
    var plainLines: [String] = []
    var entries: [(time: Double, line: LyricsDraftLine, order: Int)] = []
    let text = input.replacingOccurrences(of: "\u{FEFF}", with: "")
    if text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == instrumentalTag {
      draft.instrumental = true
      return draft
    }
    for raw in text.components(separatedBy: .newlines) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if let tag = headerTag(line) {
        if tag.name == "offset" { draft.offsetMilliseconds = Int(tag.value.trimmingCharacters(in: .whitespaces)) ?? 0 }
        else if tag.name == "au", tag.value.trimmingCharacters(in: .whitespaces).lowercased() == "instrumental" { draft.instrumental = true }
        else { draft.tags.append(line) }
        continue
      }
      var rest = Substring(line)
      var times: [Double] = []
      while rest.hasPrefix("["), let close = rest.firstIndex(of: "]"),
        let time = parseTime(rest[rest.index(after: rest.startIndex)..<close])
      {
        times.append(time)
        rest = rest[rest.index(after: close)...].drop { $0 == " " }
      }
      if times.isEmpty {
        if line.isEmpty || !line.hasPrefix("[") { plainLines.append(line) }
        continue
      }
      let (lineText, words) = parseWords(String(rest))
      for (n, time) in times.enumerated() {
        entries.append((time, LyricsDraftLine(text: lineText, start: time, words: n == 0 ? words : words.map { LyricsDraftWord(text: $0.text, start: nil) }), entries.count))
      }
    }
    entries.sort { $0.time == $1.time ? $0.order < $1.order : $0.time < $1.time }
    draft.lines = entries.map(\.line)
    let joined = plainLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    draft.plain = joined.isEmpty ? draft.lines.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n") : joined
    return draft
  }

  private static func headerTag(_ line: String) -> (name: String, value: String)? {
    guard line.hasPrefix("["), line.hasSuffix("]"), let colon = line.firstIndex(of: ":") else { return nil }
    let name = line[line.index(after: line.startIndex)..<colon]
    guard !name.isEmpty, name.allSatisfy({ $0.isLetter }) else { return nil }
    return (name.lowercased(), String(line[line.index(after: colon)..<line.index(before: line.endIndex)]))
  }

  /// "mm:ss", "mm:ss.xx" or "mm:ss:xx" to seconds.
  static func parseTime<S: StringProtocol>(_ value: S) -> Double? {
    let parts = value.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 2 || parts.count == 3, let minutes = Int(parts[0]), minutes >= 0 else { return nil }
    var secondsText = String(parts[1])
    if parts.count == 3 { secondsText += "." + parts[2] }
    let pieces = secondsText.split(separator: ".", omittingEmptySubsequences: false)
    guard pieces.count <= 2, let whole = Int(pieces[0]), (0..<60).contains(whole), pieces[0].count <= 2 else { return nil }
    var fraction = 0.0
    if pieces.count == 2 {
      guard !pieces[1].isEmpty, pieces[1].count <= 3, pieces[1].allSatisfy(\.isNumber) else { return nil }
      fraction = Double("0." + pieces[1]) ?? 0
    }
    return Double(minutes * 60 + whole) + fraction
  }

  /// Splits `<mm:ss.xx>` word tags out of a line's text.
  static func parseWords(_ text: String) -> (text: String, words: [LyricsDraftWord]) {
    var words: [LyricsDraftWord] = []
    var plain = ""
    var leading = ""
    var rest = Substring(text)
    var current: LyricsDraftWord?
    while !rest.isEmpty {
      if rest.hasPrefix("<"), let close = rest.firstIndex(of: ">"),
        let time = parseTime(rest[rest.index(after: rest.startIndex)..<close])
      {
        if let word = current, !word.text.isEmpty { words.append(word) }
        current = LyricsDraftWord(text: "", start: time)
        rest = rest[rest.index(after: close)...]
        continue
      }
      let ch = rest.removeFirst()
      plain.append(ch)
      if current != nil { current!.text.append(ch) } else { leading.append(ch) }
    }
    if let word = current, !word.text.isEmpty { words.append(word) }
    if !words.isEmpty, !leading.trimmingCharacters(in: .whitespaces).isEmpty {
      words.insert(LyricsDraftWord(text: leading, start: nil), at: 0)
    }
    return (plain.trimmingCharacters(in: .whitespaces), words)
  }

  // MARK: Writing

  static func timestamp(_ seconds: Double) -> String {
    let hundredths = Int((max(0, seconds) * 100).rounded())
    return String(format: "%02d:%02d.%02d", hundredths / 6000, (hundredths / 100) % 60, hundredths % 100)
  }

  /// The lyrics as an LRC file: synced lines (with word timings when `includeWords`
  /// and the line has them), or the plain text when nothing is synced yet.
  func lrc(includeWords: Bool = true) -> String {
    if instrumental { return Self.instrumentalTag + "\n" }
    var out = tags
    if offsetMilliseconds != 0 { out.append("[offset:\(offsetMilliseconds)]") }
    let timed = lines.filter { $0.start != nil }.sorted { $0.start! < $1.start! }
    if timed.isEmpty {
      out.append(plain.trimmingCharacters(in: .whitespacesAndNewlines))
      return out.joined(separator: "\n") + "\n"
    }
    for line in timed {
      var body = line.text
      if includeWords, line.hasWordTimings {
        body = line.words.map { word in (word.start.map { "<\(Self.timestamp($0))>" } ?? "") + word.text }.joined()
          .trimmingCharacters(in: .whitespaces)
      }
      out.append("[\(Self.timestamp(line.start!))]\(body)")
    }
    return out.joined(separator: "\n") + "\n"
  }

  /// Plain lyrics: the edited plain text, or the synced lines' text.
  var plainText: String {
    let text = plain.trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? lines.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n") : text
  }

  // MARK: Editing

  /// Turns the plain text into lines to sync, one per non-empty line (section labels
  /// such as "[Chorus]" are skipped). Lines whose text is unchanged keep their timing.
  mutating func linesFromPlain() {
    var old = lines
    var result: [LyricsDraftLine] = []
    for raw in plain.components(separatedBy: .newlines) {
      let text = raw.trimmingCharacters(in: .whitespaces)
      guard !text.isEmpty, !(text.hasPrefix("[") && text.hasSuffix("]")) else { continue }
      if let i = old.firstIndex(where: { $0.text == text }) {
        result.append(old.remove(at: i))
      } else {
        result.append(LyricsDraftLine(text: text))
      }
    }
    lines = result
  }

  /// Times a line, keeping its words' timings relative to it.
  mutating func stamp(_ index: Int, at time: Double) {
    guard lines.indices.contains(index), time.isFinite else { return }
    let time = max(0, time)
    if let old = lines[index].start {
      let delta = time - old
      for w in lines[index].words.indices { lines[index].words[w].start = lines[index].words[w].start.map { max(0, $0 + delta) } }
    }
    lines[index].start = time
  }

  mutating func nudge(_ index: Int, by delta: Double) {
    guard lines.indices.contains(index), let start = lines[index].start else { return }
    stamp(index, at: start + delta)
  }

  mutating func shiftAll(by delta: Double) {
    for i in lines.indices where lines[i].start != nil { nudge(i, by: delta) }
  }

  mutating func clearTiming(_ index: Int) {
    guard lines.indices.contains(index) else { return }
    lines[index].start = nil
    for w in lines[index].words.indices { lines[index].words[w].start = nil }
  }

  mutating func insertLine(after index: Int?, text: String = "") {
    let at = index.map { min(lines.count, $0 + 1) } ?? lines.count
    lines.insert(LyricsDraftLine(text: text), at: at)
  }

  mutating func deleteLine(_ index: Int) {
    guard lines.indices.contains(index) else { return }
    lines.remove(at: index)
  }

  mutating func setText(_ index: Int, _ text: String) {
    guard lines.indices.contains(index), lines[index].text != text else { return }
    lines[index].text = text
    // Word timings no longer match the words.
    lines[index].words = []
  }

  /// Orders lines by time (untimed lines stay after the line they followed).
  mutating func sortByTime() {
    var lastTime = -Double.infinity
    let keyed = lines.enumerated().map { (offset, line) -> (Double, Int, LyricsDraftLine) in
      if let start = line.start { lastTime = start }
      return (line.start ?? lastTime, offset, line)
    }
    lines = keyed.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }.map(\.2)
  }

  /// Splits a line into words to time, keeping timings already set for the same words.
  mutating func splitWords(_ index: Int) {
    guard lines.indices.contains(index) else { return }
    let tokens = Self.tokenize(lines[index].text)
    let old = lines[index].words
    lines[index].words = tokens.enumerated().map { (i, text) in
      LyricsDraftWord(text: text, start: old.indices.contains(i) && old[i].text == text ? old[i].start : nil)
    }
  }

  /// Spreads the line's words evenly from its start to `end` (the next line's start,
  /// or the line's start plus about a third of a second per word).
  mutating func spreadWords(_ index: Int, end: Double? = nil) {
    guard lines.indices.contains(index), let start = lines[index].start else { return }
    if lines[index].words.isEmpty { splitWords(index) }
    let count = lines[index].words.count
    guard count > 0 else { return }
    let next = end ?? lines[(index + 1)...].lazy.compactMap(\.start).first { $0 > start }
    // Most of the gap to the next line (singers pause before the next one), or about a
    // third of a second a word for the last line.
    let span = max(0.05 * Double(count), next.map { ($0 - start) * 0.9 } ?? Double(count) * 0.35)
    // Weight by letters so long words get longer.
    let weights = lines[index].words.map { max(1, Double($0.text.trimmingCharacters(in: .whitespaces).count)) }
    let total = weights.reduce(0, +)
    var t = start
    for w in lines[index].words.indices {
      lines[index].words[w].start = (t * 100).rounded() / 100
      t += span * weights[w] / total
    }
  }

  /// Times one word (and keeps later words from starting before it).
  mutating func stampWord(line index: Int, word: Int, at time: Double) {
    guard lines.indices.contains(index), lines[index].words.indices.contains(word), time.isFinite else { return }
    let time = max(0, time)
    lines[index].words[word].start = time
    if word == 0 { lines[index].start = time }
    for later in lines[index].words.indices where later > word {
      if let s = lines[index].words[later].start, s < time { lines[index].words[later].start = time }
    }
  }

  mutating func clearWords(_ index: Int) {
    guard lines.indices.contains(index) else { return }
    lines[index].words = []
  }

  /// Words: whitespace-separated, each keeping its trailing space; Chinese, Japanese
  /// and Korean ideographs and kana are timed one character at a time.
  static func tokenize(_ text: String) -> [String] {
    var tokens: [String] = []
    var current = ""
    func flush() { if !current.isEmpty { tokens.append(current); current = "" } }
    for ch in text.trimmingCharacters(in: .whitespaces) {
      if ch.isWhitespace {
        if !current.isEmpty { current.append(" ") }
        flush()
      } else if isCJK(ch) {
        flush()
        tokens.append(String(ch))
      } else {
        if let last = current.last, last == " " { flush() }
        current.append(ch)
      }
    }
    flush()
    return tokens.filter { !$0.isEmpty }
  }

  private static func isCJK(_ ch: Character) -> Bool {
    ch.unicodeScalars.contains { scalar in
      switch scalar.value {
      case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F: return true
      default: return false
      }
    }
  }

  // MARK: Playback

  func activeLine(at time: Double) -> Int? {
    let time = time + Double(offsetMilliseconds) / 1000
    var best: Int?
    var bestStart = -Double.infinity
    for (i, line) in lines.enumerated() {
      if let start = line.start, start <= time, start >= bestStart { best = i; bestStart = start }
    }
    return best
  }

  func activeWord(line index: Int, at time: Double) -> Int? {
    guard lines.indices.contains(index) else { return nil }
    let time = time + Double(offsetMilliseconds) / 1000
    return lines[index].words.lastIndex { ($0.start ?? .infinity) <= time }
  }

  // MARK: Checks

  /// Lyripass-style checks: untimed lines, lines out of order, the same time twice,
  /// lines ending in a comma or full stop, and stray blank lines in plain text.
  func problems() -> [LyricsProblem] {
    guard !instrumental else { return [] }
    var result: [LyricsProblem] = []
    var previous: Double?
    for (i, line) in lines.enumerated() {
      let n = i + 1
      guard let start = line.start else {
        result.append(LyricsProblem(line: n, severity: .warning, message: "Line \(n) isn’t synced yet"))
        continue
      }
      if let previous, start < previous {
        result.append(LyricsProblem(line: n, severity: .error, message: "Line \(n) starts before the line above it"))
      } else if let previous, start == previous, !line.text.isEmpty {
        result.append(LyricsProblem(line: n, severity: .warning, message: "Line \(n) starts at the same time as the line above"))
      }
      previous = start
      let trimmed = line.text.trimmingCharacters(in: .whitespaces)
      if (trimmed.hasSuffix(".") && !trimmed.hasSuffix("...")) || trimmed.hasSuffix(",") {
        result.append(LyricsProblem(line: n, severity: .warning, message: "Line \(n) ends with a comma or full stop"))
      }
      var wordTime = start
      for word in line.words {
        if let s = word.start {
          if s < wordTime - 0.001 {
            result.append(LyricsProblem(line: n, severity: .error, message: "A word in line \(n) is timed before the word or line before it"))
            break
          }
          wordTime = s
        }
      }
    }
    if lines.isEmpty {
      let plainLines = plain.components(separatedBy: .newlines)
      for i in plainLines.indices where i > 0 && plainLines[i].trimmingCharacters(in: .whitespaces).isEmpty
        && plainLines[i - 1].trimmingCharacters(in: .whitespaces).isEmpty
      {
        result.append(LyricsProblem(line: i + 1, severity: .warning, message: "Extra empty line at line \(i + 1)"))
      }
    }
    return result
  }
}
