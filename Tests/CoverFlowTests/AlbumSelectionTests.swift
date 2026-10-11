import XCTest
@testable import CoverFlow

final class AlbumSelectionTests: XCTestCase {
    func testShiftRangeKeepsAnchorAndCanShrink() {
        let ids = (0..<6).map { _ in UUID() }
        var selection = AlbumSelection()
        selection.select(ids[1], ordered: ids)
        selection.select(ids[5], ordered: ids, extend: true)
        XCTAssertEqual(selection.ids, Set(ids[1...5]))
        selection.select(ids[3], ordered: ids, extend: true)
        XCTAssertEqual(selection.ids, Set(ids[1...3]))
        selection.select(ids[0], ordered: ids, extend: true)
        XCTAssertEqual(selection.ids, Set(ids[0...1]))
    }

    func testCommandTogglesAndShiftCommandAddsRange() {
        let ids = (0..<6).map { _ in UUID() }
        var selection = AlbumSelection()
        selection.select(ids[0], ordered: ids)
        selection.select(ids[3], ordered: ids, toggle: true)
        selection.select(ids[5], ordered: ids, extend: true, toggle: true)
        XCTAssertEqual(selection.ids, Set([ids[0]] + Array(ids[3...5])))
        selection.select(ids[3], ordered: ids, toggle: true)
        XCTAssertFalse(selection.ids.contains(ids[3]))
    }

    func testDragSelectionAndFilteredAlbums() {
        let ids = (0..<6).map { _ in UUID() }
        var selection = AlbumSelection()
        selection.marquee(intersecting: Set(ids[2...4]), addingTo: [ids[0]])
        selection.finishMarquee(ordered: ids)
        XCTAssertEqual(selection.anchor, ids[0])
        selection.retainVisible(Array(ids[2...3]))
        XCTAssertEqual(selection.ids, Set(ids[2...3]))
        XCTAssertNil(selection.anchor)
        selection.select(ids[3], ordered: Array(ids[2...3]), extend: true)
        XCTAssertEqual(selection.ids, [ids[3]])
        selection.selectAll(ids)
        XCTAssertEqual(selection.ids.count, 6)
        selection.clear()
        XCTAssertTrue(selection.ids.isEmpty)
        XCTAssertNil(selection.anchor)
    }

    func testRangeUsesCurrentDisplayedOrder() {
        let ids = (0..<5).map { _ in UUID() }
        var selection = AlbumSelection()
        selection.select(ids[2], ordered: ids)
        let reordered = [ids[2], ids[4], ids[0], ids[3], ids[1]]
        selection.select(ids[0], ordered: reordered, extend: true)
        XCTAssertEqual(selection.ids, Set(reordered[0...2]))
    }
}
