import Foundation

/// A bounded handoff from the audio render thread to the visualizer. The render
/// callback never waits, allocates, invokes UI code, or touches the OpenGL engine.
final class VisualizerAudioBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float]
    private var writeIndex = 0
    private var available = 0
    private var enabled = false

    init(capacity: Int = 8192) { samples = Array(repeating: 0, count: max(2, capacity) * 2) }

    func setEnabled(_ value: Bool) {
        lock.lock()
        enabled = value
        available = 0
        lock.unlock()
    }

    func clear() {
        lock.lock()
        available = 0
        lock.unlock()
    }

    func append(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int) {
        guard frames > 0 else { return }
        guard lock.try() else { return }
        defer { lock.unlock() }
        guard enabled else { return }
        let capacity = samples.count / 2
        for i in max(0, frames - capacity)..<frames {
            samples[writeIndex * 2] = left[i]
            samples[writeIndex * 2 + 1] = right[i]
            writeIndex = (writeIndex + 1) % capacity
        }
        available = min(capacity, available + frames)
    }

    /// Consume only the most recent samples; old frames never build up latency.
    func drain(into output: UnsafeMutableBufferPointer<Float>) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let capacity = samples.count / 2
        let frames = min(available, output.count / 2)
        let start = (writeIndex - frames + capacity) % capacity
        for i in 0..<frames {
            let index = (start + i) % capacity
            output[i * 2] = samples[index * 2]
            output[i * 2 + 1] = samples[index * 2 + 1]
        }
        available = 0
        return frames
    }
}
