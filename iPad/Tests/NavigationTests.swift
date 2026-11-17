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
      XCTAssertLessThanOrEqual(layout.coverSide, width >= 600 ? 560 : 340)
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

final class FoldTests: XCTestCase {
  typealias R = FoldGeometry.RectValue
  typealias S = FoldGeometry.CGSizeValue
  // iPhone Duo inner display sizes measured on the iOS 27.1 simulator.
  let portrait = S(width: 669, height: 951)
  let landscape = S(width: 951, height: 669)

  func testLayoutClassFollowsWidthNotDevice() {
    XCTAssertEqual(MobileLayoutClass(regularWidth: false), .compact)
    XCTAssertEqual(MobileLayoutClass(regularWidth: true), .expanded)
    // Duo outer display in landscape is compact both ways; a landscape Max phone is
    // regular width but compact height, and keeps the phone layout.
    XCTAssertEqual(MobileLayoutClass(regularWidth: false, regularHeight: false), .compact)
    XCTAssertEqual(MobileLayoutClass(regularWidth: true, regularHeight: false), .compact)
    XCTAssertEqual(MobileLayoutClass(regularWidth: true, regularHeight: true), .expanded)
  }
  func testFlatWithoutAnActiveDivision() {
    let fold = FoldGeometry(size: portrait, division: nil)
    XCTAssertEqual(fold.posture, .flat)
    XCTAssertEqual(fold.leadingPaneWidth(), 368)
    XCTAssertEqual(fold.paneGap, 0)
    XCTAssertNil(fold.tabletopUpperHeight)
    XCTAssertTrue(fold.prefersTwoPanes)
    XCTAssertFalse(FoldGeometry(size: S(width: 466, height: 678), division: nil).prefersTwoPanes)
  }
  func testVerticalFoldIsBookAndPanesMeetAtTheFold() {
    let fold = FoldGeometry(size: portrait, division: R(x: 330, y: 0, width: 9, height: 951))
    XCTAssertEqual(fold.posture, .book)
    XCTAssertEqual(fold.leadingPaneWidth(), 330)
    XCTAssertEqual(fold.paneGap, 9)
    XCTAssertTrue(fold.prefersTwoPanes)
    XCTAssertEqual(fold.gridColumns(minimumWidth: 150) % 2, 0)
  }
  func testHorizontalFoldIsTabletop() {
    let fold = FoldGeometry(size: landscape, division: R(x: 0, y: 330, width: 951, height: 9))
    XCTAssertEqual(fold.posture, .tabletop)
    XCTAssertEqual(fold.tabletopUpperHeight, 330)
    XCTAssertEqual(fold.paneGap, 0)
  }
  func testFoldOutsideThisViewOrTooCloseToAnEdgeIsIgnoredForPanes() {
    XCTAssertEqual(
      FoldGeometry(size: portrait, division: R(x: 900, y: 0, width: 9, height: 951)).posture, .flat)
    let edge = FoldGeometry(size: portrait, division: R(x: 100, y: 0, width: 9, height: 951))
    XCTAssertEqual(edge.posture, .book)
    XCTAssertEqual(edge.leadingPaneWidth(), 368)
    XCTAssertEqual(edge.paneGap, 0)
    let invalid = FoldGeometry(size: portrait, division: R(x: .nan, y: 0, width: 9, height: 951))
    XCTAssertEqual(invalid.posture, .flat)
  }
  func testHingeAngleIsKeptOnlyWhenFinite() {
    XCTAssertEqual(FoldGeometry(size: portrait, division: nil, hingeDegrees: 110).hingeDegrees, 110)
    XCTAssertNil(FoldGeometry(size: portrait, division: nil, hingeDegrees: .nan).hingeDegrees)
  }
}
