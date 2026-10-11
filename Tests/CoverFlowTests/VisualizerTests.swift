import XCTest
import CProjectM
@testable import CoverFlow

final class VisualizerTests: XCTestCase {
    private func append(_ values: [Float], to buffer: VisualizerAudioBuffer) {
        let right = values.map { -$0 }
        values.withUnsafeBufferPointer { left in
            right.withUnsafeBufferPointer { right in
                buffer.append(left: left.baseAddress!, right: right.baseAddress!, frames: values.count)
            }
        }
    }
    private func drain(_ buffer: VisualizerAudioBuffer, capacity: Int = 32) -> [Float] {
        var samples = Array(repeating: Float(0), count: capacity * 2)
        let count = samples.withUnsafeMutableBufferPointer { buffer.drain(into: $0) }
        return Array(samples.prefix(count * 2))
    }

    func testStereoOrderingAndConsumption() {
        let buffer = VisualizerAudioBuffer()
        buffer.setEnabled(true)
        append([1, 2, 3], to: buffer)
        XCTAssertEqual(drain(buffer), [1, -1, 2, -2, 3, -3])
        XCTAssertTrue(drain(buffer).isEmpty)
    }
    func testWraparoundKeepsNewestFrames() {
        let buffer = VisualizerAudioBuffer(capacity: 4)
        buffer.setEnabled(true)
        append([1, 2, 3], to: buffer)
        append([4, 5, 6], to: buffer)
        XCTAssertEqual(drain(buffer), [3, -3, 4, -4, 5, -5, 6, -6])
        append([1, 2, 3, 4, 5, 6, 7], to: buffer)
        XCTAssertEqual(drain(buffer, capacity: 2), [6, -6, 7, -7])
        XCTAssertTrue(drain(buffer).isEmpty)
    }
    func testDisableAndSeekClearStaleAudio() {
        let buffer = VisualizerAudioBuffer()
        append([1], to: buffer)
        XCTAssertTrue(drain(buffer).isEmpty)
        buffer.setEnabled(true)
        append([2], to: buffer)
        buffer.clear()
        XCTAssertTrue(drain(buffer).isEmpty)
        append([3], to: buffer)
        buffer.setEnabled(false)
        buffer.setEnabled(true)
        XCTAssertTrue(drain(buffer).isEmpty)
    }
    func testMissingEngineReportsRecoverableError() {
        let visualizer = cf_visualizer_create("/nonexistent/coverflow-projectm.dylib")
        defer { cf_visualizer_destroy(visualizer) }
        XCTAssertNotNil(visualizer)
        XCTAssertFalse(String(cString: cf_visualizer_error(visualizer)).isEmpty)
        XCTAssertFalse(cf_visualizer_load(visualizer, "/nonexistent/preset.milk", false))
    }
}
