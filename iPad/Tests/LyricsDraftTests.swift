import XCTest

@testable import iPadSignal

final class LyricsDraftTests: XCTestCase {
  func testParsesSyncedLinesWordsTagsAndPlain() {
    let draft = LyricsDraft.parse(
      "[ti:Song]\n[offset:250]\n[00:12.34]<00:12.34>Hello <00:12.80>world\n[00:10.00][00:20.5]Again\nNot timed")
    XCTAssertEqual(draft.tags, ["[ti:Song]"])
    XCTAssertEqual(draft.offsetMilliseconds, 250)
    XCTAssertEqual(draft.lines.map(\.text), ["Again", "Hello world", "Again"])
    XCTAssertEqual(draft.lines.map(\.start), [10, 12.34, 20.5])
    XCTAssertEqual(draft.lines[1].words, [
      LyricsDraftWord(text: "Hello ", start: 12.34), LyricsDraftWord(text: "world", start: 12.8),
    ])
    XCTAssertEqual(draft.plain, "Not timed")
  }

  func testRoundTripsEnhancedLRC() {
    let source = "[ar:Artist]\n[00:01.00]<00:01.00>One <00:01.50>two\n[00:03.25]Three\n"
    let draft = LyricsDraft.parse(source)
    XCTAssertEqual(draft.lrc(), source)
    XCTAssertEqual(draft.lrc(includeWords: false), "[ar:Artist]\n[00:01.00]One two\n[00:03.25]Three\n")
  }

  func testInstrumentalAndPlain() {
    XCTAssertTrue(LyricsDraft.parse("[au: instrumental]").instrumental)
    var draft = LyricsDraft.parse("First line\n\nSecond line\n")
    XCTAssertFalse(draft.isSynced)
    XCTAssertEqual(draft.lrc(), "First line\n\nSecond line\n")
    draft.instrumental = true
    XCTAssertEqual(draft.lrc(), "[au: instrumental]\n")
  }

  func testLinesFromPlainKeepTimingsAndSkipSections() {
    var draft = LyricsDraft.parse("[00:05.00]Keep me\n")
    draft.plain = "[Verse]\nNew start\nKeep me\n\nEnd"
    draft.linesFromPlain()
    XCTAssertEqual(draft.lines.map(\.text), ["New start", "Keep me", "End"])
    XCTAssertEqual(draft.lines.map(\.start), [nil, 5, nil])
    XCTAssertEqual(draft.unsyncedCount, 2)
    // Only timed lines are written.
    XCTAssertEqual(draft.lrc(), "[00:05.00]Keep me\n")
  }

  func testStampNudgeAndShiftMoveWords() {
    var draft = LyricsDraft.parse("[00:01.00]<00:01.00>A <00:01.40>B\n")
    draft.nudge(0, by: 0.1)
    XCTAssertEqual(draft.lines[0].start!, 1.1, accuracy: 0.0001)
    XCTAssertEqual(draft.lines[0].words[1].start!, 1.5, accuracy: 0.0001)
    draft.shiftAll(by: -2)
    XCTAssertEqual(draft.lines[0].start, 0)
    XCTAssertEqual(draft.lines[0].words[1].start!, 0.4, accuracy: 0.0001)
    draft.stamp(0, at: 4)
    XCTAssertEqual(draft.lines[0].start, 4)
  }

  func testTokenizeAndSpreadWords() {
    XCTAssertEqual(LyricsDraft.tokenize("  Hello there  world "), ["Hello ", "there ", "world"])
    XCTAssertEqual(LyricsDraft.tokenize("君の名は ok"), ["君", "の", "名", "は", "ok"])
    var draft = LyricsDraft()
    draft.lines = [LyricsDraftLine(text: "aa bb", start: 10), LyricsDraftLine(text: "Next", start: 12)]
    draft.spreadWords(0)
    XCTAssertEqual(draft.lines[0].words.map(\.text), ["aa ", "bb"])
    XCTAssertEqual(draft.lines[0].words[0].start, 10)
    XCTAssertEqual(draft.lines[0].words[1].start!, 10.9, accuracy: 0.011)
    XCTAssertEqual(draft.lrc(), "[00:10.00]<00:10.00>aa <00:10.90>bb\n[00:12.00]Next\n")
    draft.stampWord(line: 0, word: 0, at: 10.5)
    XCTAssertEqual(draft.lines[0].start, 10.5)
    XCTAssertEqual(draft.lines[0].words[1].start, 10.9)
    draft.stampWord(line: 0, word: 0, at: 11)
    XCTAssertEqual(draft.lines[0].words[1].start, 11)
    draft.setText(0, "changed text")
    XCTAssertTrue(draft.lines[0].words.isEmpty)
  }

  func testActiveLineWordAndProblems() {
    var draft = LyricsDraft.parse("[00:01.00]<00:01.00>One <00:02.00>two\n[00:05.00]Three.\n")
    XCTAssertNil(draft.activeLine(at: 0.5))
    XCTAssertEqual(draft.activeLine(at: 1.5), 0)
    XCTAssertEqual(draft.activeWord(line: 0, at: 2.1), 1)
    XCTAssertEqual(draft.activeLine(at: 9), 1)
    draft.insertLine(after: 1, text: "Four")
    draft.lines[0].start = 6
    let messages = draft.problems().map(\.message)
    XCTAssertTrue(messages.contains("Line 2 starts before the line above it"))
    XCTAssertTrue(messages.contains("Line 2 ends with a comma or full stop"))
    XCTAssertTrue(messages.contains("Line 3 isn’t synced yet"))
    draft.sortByTime()
    XCTAssertEqual(draft.lines.map(\.text), ["Three.", "Four", "One two"])
  }

  func testTimestampFormatting() {
    XCTAssertEqual(LyricsDraft.timestamp(0), "00:00.00")
    XCTAssertEqual(LyricsDraft.timestamp(83.456), "01:23.46")
    XCTAssertEqual(LyricsDraft.parseTime("1:02:5"), 62.5)
    XCTAssertNil(LyricsDraft.parseTime("00:75"))
  }
}
