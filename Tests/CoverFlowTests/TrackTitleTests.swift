import XCTest
@testable import CoverFlow

final class TrackTitleTests: XCTestCase {
    func testShortTitlesStayStillAndInvalidGeometryDoesNotAnimate() {
        for distance: CGFloat in [-20, 0, 1, .nan, .infinity] {
            XCTAssertEqual(TrackTitleScroll.offset(distance: distance, elapsed: 10), 0)
        }
        XCTAssertEqual(TrackTitleScroll.offset(distance: 400, elapsed: -.infinity), 0)
    }

    func testLongTitleRevealsItsEndAndReturnsToTheBeginning() {
        let distance: CGFloat = 280
        XCTAssertEqual(TrackTitleScroll.offset(distance: distance, elapsed: 0), 0)
        XCTAssertEqual(TrackTitleScroll.offset(distance: distance, elapsed: 1.5), 0)
        XCTAssertEqual(TrackTitleScroll.offset(distance: distance, elapsed: 7), 140)
        XCTAssertEqual(TrackTitleScroll.offset(distance: distance, elapsed: 12.5), distance)
        XCTAssertEqual(TrackTitleScroll.offset(distance: distance, elapsed: 19), 140)
        XCTAssertEqual(TrackTitleScroll.offset(distance: distance, elapsed: 24), 0)
        XCTAssertEqual(TrackTitleScroll.offset(distance: distance, elapsed: 25), 0)
    }

    func testVeryLongTitlesKeepReadableSpeedWithoutOvershooting() {
        let distance: CGFloat = 12_000
        XCTAssertEqual(TrackTitleScroll.offset(distance: distance, elapsed: 7), 140)
        for time in stride(from: 0.0, to: 2000, by: 0.5) {
            let offset = TrackTitleScroll.offset(distance: distance, elapsed: time)
            XCTAssertTrue((0...distance).contains(offset))
        }
    }

    func testLongUnicodeAndMultilineTitlesGetWideAlbumRows() {
        XCTAssertFalse(TrackTitleLayout.needsWideColumn("Song"))
        XCTAssertFalse(TrackTitleLayout.needsWideColumn(""))
        XCTAssertTrue(TrackTitleLayout.needsWideColumn("Piano Concerto No. 2 in C minor, Op. 18: II. Adagio sostenuto — Live at the Royal Albert Hall"))
        XCTAssertTrue(TrackTitleLayout.needsWideColumn(String(repeating: "夜の音楽 🎵 ", count: 12)))
        XCTAssertTrue(TrackTitleLayout.needsWideColumn("Part I\nPart II"))
        XCTAssertTrue(TrackTitleLayout.needsWideColumn(String(repeating: "W", count: 200)))
    }
}
