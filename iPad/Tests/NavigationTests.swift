import XCTest

@testable import iPadSignal

final class NavigationTests: XCTestCase {
  func testEveryTabletDestinationIsReachableInFivePhoneTabs() {
    XCTAssertEqual(MobileTab.compactTabs.count, 5)
    XCTAssertEqual(MobileTab.sidebarTabs.count, 6)
    XCTAssertFalse(MobileTab.sidebarTabs.contains(.more))
    for destination in MobileTab.sidebarTabs {
      XCTAssertTrue(MobileTab.compactTabs.contains(destination.compactSelection))
      XCTAssertEqual(destination.compactSelection == .more, destination.isSecondaryDestination)
    }
    XCTAssertEqual(MobileTab.visualizer.compactSelection, .more)
    XCTAssertEqual(MobileTab.settings.compactSelection, .more)
  }
  func testSmallAndLandscapeLayoutsKeepCoversAndCaptionsReachable() {
    for (width, height) in [(320.0, 350.0), (390, 540), (844, 140), (1024, 650)] {
      let layout = MobileCoverLayout(width: width, height: height)
      XCTAssertLessThanOrEqual(layout.coverSide, width * 0.72)
      XCTAssertLessThanOrEqual(layout.coverSide, 340)
      XCTAssertGreaterThanOrEqual(layout.stageHeight, layout.coverSide + 142)
      XCTAssertGreaterThanOrEqual(layout.stageHeight, height)
    }
    // Short landscape screens can scroll instead of clipping the caption.
    XCTAssertGreaterThan(MobileCoverLayout(width: 844, height: 140).stageHeight, 140)
    let invalid = MobileCoverLayout(width: .nan, height: .infinity)
    XCTAssertTrue(invalid.coverSide.isFinite)
    XCTAssertTrue(invalid.stageHeight.isFinite)
  }
  func testCarouselSnapsToCenteredCoversIncludingShortCollectionsAndEdges() {
    XCTAssertEqual(MobileCoverLayout.snapOffset(predicted: 800, step: 104, count: 1), 0)
    XCTAssertEqual(MobileCoverLayout.snapOffset(predicted: -30, step: 104, count: 3), 0)
    XCTAssertEqual(MobileCoverLayout.snapOffset(predicted: 63, step: 104, count: 3), 104)
    XCTAssertEqual(MobileCoverLayout.snapOffset(predicted: 999, step: 104, count: 3), 208)
    XCTAssertEqual(MobileCoverLayout.snapOffset(predicted: .infinity, step: 0, count: 3), 0)
  }

}
