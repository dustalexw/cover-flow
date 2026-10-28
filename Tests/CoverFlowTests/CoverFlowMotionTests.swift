import AppKit
import XCTest
@testable import CoverFlow

final class CoverFlowMotionTests: XCTestCase {
    @MainActor
    func testTinyEdgeScrollIsResistedAndZeroDeltaEventsCannotAmplifyIt() {
        let flow = CoverFlowController(); flow.count = 10
        flow.scrollPrecise(delta: 1, unit: 100, phase: .began, momentumPhase: [])
        let position = flow.position
        XCTAssertLessThan(position, 0)
        XCTAssertLessThan(abs(position), 0.01)
        for _ in 0..<30 { flow.scrollPrecise(delta: 0, unit: 100, phase: .changed, momentumPhase: []) }
        XCTAssertEqual(flow.position, position)
        flow.scrollPrecise(delta: -1, unit: 100, phase: .changed, momentumPhase: [])
        XCTAssertEqual(flow.position, 0, accuracy: 1e-10)
    }

    @MainActor
    func testFingerPauseAndMomentumDoNotTriggerCompetingSnaps() async throws {
        let flow = CoverFlowController(); flow.count = 10
        flow.go(to: 5, animated: false)
        flow.scrollPrecise(delta: 60, unit: 100, phase: .began, momentumPhase: [])
        try await Task.sleep(for: .milliseconds(260))
        XCTAssertEqual(flow.position, 4.4, accuracy: 1e-10)
        flow.scrollPrecise(delta: 0, unit: 100, phase: .ended, momentumPhase: [])
        flow.scrollPrecise(delta: 10, unit: 100, phase: [], momentumPhase: .began)
        try await Task.sleep(for: .milliseconds(260))
        XCTAssertEqual(flow.position, 4.3, accuracy: 1e-10)
        flow.scrollPrecise(delta: 0, unit: 100, phase: [], momentumPhase: .ended)
        XCTAssertEqual(flow.position, 4)
        XCTAssertEqual(flow.target, 4)
    }

    @MainActor
    func testPhaseLessPreciseDevicesStillSettleAfterIdle() async throws {
        let flow = CoverFlowController(); flow.count = 10
        flow.go(to: 3, animated: false)
        flow.scrollPrecise(delta: 30, unit: 100, phase: [], momentumPhase: [])
        XCTAssertEqual(flow.position, 2.7, accuracy: 1e-10)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(flow.position, 3)
    }

    @MainActor
    func testBothCollectionEdgesStayBoundedAndNewNavigationResetsTheGesture() {
        let flow = CoverFlowController(); flow.count = 5
        for _ in 0..<100 { flow.scrollPrecise(delta: 100, unit: 100, phase: .changed, momentumPhase: []) }
        XCTAssertGreaterThan(flow.position, -0.25)
        flow.go(to: 4, animated: false)
        for _ in 0..<100 { flow.scrollPrecise(delta: -100, unit: 100, phase: .changed, momentumPhase: []) }
        XCTAssertLessThan(flow.position, 4.25)
        flow.go(to: 2, animated: false)
        flow.scrollPrecise(delta: 10, unit: 100, phase: .began, momentumPhase: [])
        XCTAssertEqual(flow.position, 1.9, accuracy: 1e-10)
        flow.scrollPrecise(delta: 100, unit: 0, phase: .changed, momentumPhase: [])
        XCTAssertEqual(flow.position, 1.9, accuracy: 1e-10)
    }

    func testCoverTransformsKeepTheirArrangementAndHaveContinuousSpeedAtTheFold() {
        for reduced in [false, true] {
            func geometry(_ d: Double) -> CoverFlowGeometry { .init(distance: d, size: 100, reduceMotion: reduced) }
            XCTAssertEqual(geometry(0).offset, 0)
            XCTAssertEqual(geometry(1).offset, 68, accuracy: 1e-10)
            XCTAssertEqual(geometry(2).offset, reduced ? 98 : 86, accuracy: 1e-10)
            XCTAssertEqual(geometry(0).angle, 0)
            XCTAssertEqual(geometry(1).angle, reduced ? 0 : -62)
            let h = 0.0001
            for key in [\CoverFlowGeometry.offset, \.angle, \.scale] {
                let before = (geometry(1)[keyPath: key] - geometry(1 - h)[keyPath: key]) / h
                let after = (geometry(1 + h)[keyPath: key] - geometry(1)[keyPath: key]) / h
                XCTAssertEqual(before, after, accuracy: 0.03)
            }
            for d in [0.01, 0.4, 0.99, 1.5] {
                XCTAssertEqual(geometry(-d).offset, -geometry(d).offset, accuracy: 1e-10)
                XCTAssertEqual(geometry(-d).angle, -geometry(d).angle, accuracy: 1e-10)
                XCTAssertEqual(geometry(-d).scale, geometry(d).scale)
            }
        }
    }
}
