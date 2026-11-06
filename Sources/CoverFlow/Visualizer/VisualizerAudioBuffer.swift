import AudioToolbox
import AVFoundation
import Foundation

/// A bounded handoff from the audio render thread to the visualizer. The render
/// callback never waits, allocates, invokes UI code, or touches the OpenGL engine.
///
/// Audio arrives from one of two places. The preferred one is the output unit's render
/// notification (`OutputRenderTap`): every hardware I/O cycle, about 10 ms, so the
/// visualizer sees each slice of sound just before it is heard. AVAudioEngine's mixer
/// tap is the fallback; macOS hands it 100 ms or more at a time, which makes motion
/// arrive in jumps. While output cycles are arriving, tap buffers are ignored so the
/// same audio is never counted twice.
final class VisualizerAudioBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float]
    private var writeIndex = 0
    private var available = 0
    private var enabled = false
    private var lastOutputAppend: UInt64 = 0
    private let outputHoldTicks: UInt64

    init(capacity: Int = 8192) {
        samples = Array(repeating: 0, count: max(2, capacity) * 2)
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        // 0.25 s in host ticks: how long a silent output path keeps the tap muted.
        outputHoldTicks = UInt64(250_000_000) * UInt64(timebase.denom) / UInt64(max(1, timebase.numer))
    }

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

    /// Whether the low-latency output path has delivered audio in the last 0.25 s.
    var receivesOutputCycles: Bool {
        lock.lock(); defer { lock.unlock() }
        return lastOutputAppend != 0 && mach_absolute_time() &- lastOutputAppend < outputHoldTicks
    }

    /// `fromOutput` marks audio from the output unit's render cycle; tap audio is
    /// dropped while those cycles are arriving.
    func append(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int, fromOutput: Bool = false) {
        guard frames > 0 else { return }
        guard lock.try() else { return }
        defer { lock.unlock() }
        guard enabled else { return }
        let now = mach_absolute_time()
        if fromOutput {
            lastOutputAppend = now
        } else if lastOutputAppend != 0 && now &- lastOutputAppend < outputHoldTicks {
            return
        }
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

/// Copies what the output unit renders, every I/O cycle, into a VisualizerAudioBuffer.
/// Runs on the real-time render thread: no allocation, locking (beyond the buffer's
/// try-lock) or Objective-C messaging there. Formats it can't read (non-float) are
/// skipped, which leaves the mixer tap in charge.
final class OutputRenderTap {
    private final class Context {
        let audio: VisualizerAudioBuffer
        var channels = 0
        var interleaved = false
        var isFloat = false
        let capacity = 8192
        let left: UnsafeMutablePointer<Float>
        let right: UnsafeMutablePointer<Float>
        init(audio: VisualizerAudioBuffer) {
            self.audio = audio
            left = .allocate(capacity: capacity); left.initialize(repeating: 0, count: capacity)
            right = .allocate(capacity: capacity); right.initialize(repeating: 0, count: capacity)
        }
        deinit { left.deallocate(); right.deallocate() }
    }

    private let context: Context
    private var unit: AudioUnit?
    private var installed = false

    init(audio: VisualizerAudioBuffer) { context = Context(audio: audio) }
    deinit { uninstall() }

    /// Attaches to the engine's output unit (again after a device or format change).
    @discardableResult
    func install(on engine: AVAudioEngine) -> Bool {
        uninstall()
        guard !engine.isInManualRenderingMode, let unit = engine.outputNode.audioUnit else { return false }
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        // The output unit's input scope is the format the engine renders into it.
        guard AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, &size) == noErr,
              format.mFormatID == kAudioFormatLinearPCM, format.mBitsPerChannel == 32,
              format.mChannelsPerFrame > 0 else { return false }
        context.isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        context.interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        context.channels = Int(format.mChannelsPerFrame)
        guard context.isFloat else { return false }
        let refCon = Unmanaged.passUnretained(context).toOpaque()
        guard AudioUnitAddRenderNotify(unit, OutputRenderTap.notify, refCon) == noErr else { return false }
        self.unit = unit
        installed = true
        return true
    }

    func uninstall() {
        guard installed, let unit else { return }
        AudioUnitRemoveRenderNotify(unit, OutputRenderTap.notify, Unmanaged.passUnretained(context).toOpaque())
        installed = false
        self.unit = nil
    }

    private static let notify: AURenderCallback = { refCon, flags, _, _, frameCount, ioData in
        guard flags.pointee.contains(.unitRenderAction_PostRender), let ioData, frameCount > 0 else { return noErr }
        let context = Unmanaged<Context>.fromOpaque(refCon).takeUnretainedValue()
        let buffers = UnsafeMutableAudioBufferListPointer(ioData)
        let frames = min(Int(frameCount), context.capacity)
        guard context.isFloat, buffers.count > 0 else { return noErr }
        if context.interleaved {
            guard let data = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let stride = max(1, context.channels)
            let second = stride > 1 ? 1 : 0
            for i in 0..<frames {
                context.left[i] = data[i * stride]
                context.right[i] = data[i * stride + second]
            }
            context.audio.append(left: context.left, right: context.right, frames: frames, fromOutput: true)
        } else {
            guard let left = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let right = buffers.count > 1 ? (buffers[1].mData?.assumingMemoryBound(to: Float.self) ?? left) : left
            context.audio.append(left: left, right: right, frames: frames, fromOutput: true)
        }
        return noErr
    }
}
