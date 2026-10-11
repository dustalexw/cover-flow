import AVFoundation

/// Decodes a bounded amount of audio off the main thread. Every track uses the same
/// output format so the player node can join buffers without restarting the device.
actor PCMDecoder {
    static let sampleRate = 48_000.0
    static let chunkFrames: AVAudioFrameCount = 24_000
    static var outputFormat: AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    }

    struct Chunk: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        let isLast: Bool
    }

    private let file: PCMFileReader
    private let converter: AVAudioConverter?
    private let input: AVAudioPCMBuffer
    private let totalOutputFrames: AVAudioFramePosition
    private var emittedFrames: AVAudioFramePosition = 0
    let duration: Double

    init(url: URL, start: Double = 0) throws {
        file = try PCMFileReader(url: url)
        guard file.length > 0 else { throw CocoaError(.fileReadCorruptFile) }
        let format = file.format
        duration = Double(file.length) / format.sampleRate
        let startFrame = min(file.length, max(0, AVAudioFramePosition(start * format.sampleRate)))
        if startFrame > 0 { try file.seek(to: startFrame) }
        totalOutputFrames = AVAudioFramePosition((Double(file.length - startFrame) * Self.sampleRate / format.sampleRate).rounded())
        input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_192)!
        if format == Self.outputFormat {
            converter = nil
        } else {
            guard let conversion = AVAudioConverter(from: format, to: Self.outputFormat) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            // Normal priming removes resampler latency from the output. Disabling
            // priming would insert silent frames at sample-rate changes.
            conversion.primeMethod = .normal
            if format.channelCount == 1 { conversion.channelMap = [0, 0] }
            converter = conversion
        }
    }

    func read() throws -> Chunk? {
        let remaining = totalOutputFrames - emittedFrames
        guard remaining > 0 else { return nil }
        let count = AVAudioFrameCount(min(AVAudioFramePosition(Self.chunkFrames), remaining))
        let output = AVAudioPCMBuffer(pcmFormat: Self.outputFormat, frameCapacity: count)!
        if let converter {
            var conversionError: NSError?
            var readError: Error?
            let status = converter.convert(to: output, error: &conversionError) { [file, input] _, status in
                do {
                    try file.read(into: input)
                    status.pointee = input.frameLength > 0 ? .haveData : .endOfStream
                    return input.frameLength > 0 ? input : nil
                } catch {
                    readError = error
                    status.pointee = .endOfStream
                    return nil
                }
            }
            if let readError { throw readError }
            if let conversionError { throw conversionError }
            if status == .error { throw CocoaError(.fileReadCorruptFile) }
        } else {
            try file.read(into: output, frameCount: count)
        }
        guard output.frameLength > 0 else { return nil }
        emittedFrames += AVAudioFramePosition(output.frameLength)
        return Chunk(buffer: output, isLast: emittedFrames >= totalOutputFrames)
    }
}

/// The throwing Core Audio APIs also report damaged/unsupported files without
/// AVAudioFile's frame-position setter raising an Objective-C exception.
private final class PCMFileReader {
    private let reference: ExtAudioFileRef
    let format: AVAudioFormat
    let length: AVAudioFramePosition

    init(url: URL) throws {
        var opened: ExtAudioFileRef?
        try Self.check(ExtAudioFileOpenURL(url as CFURL, &opened))
        guard let opened else { throw CocoaError(.fileReadCorruptFile) }
        var initialized = false
        defer { if !initialized { ExtAudioFileDispose(opened) } }
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try Self.check(ExtAudioFileGetProperty(opened, kExtAudioFileProperty_FileDataFormat, &size, &description))
        guard let format = AVAudioFormat(standardFormatWithSampleRate: description.mSampleRate,
                                        channels: description.mChannelsPerFrame) else { throw CocoaError(.fileReadCorruptFile) }
        var frames: Int64 = 0
        size = UInt32(MemoryLayout<Int64>.size)
        try Self.check(ExtAudioFileGetProperty(opened, kExtAudioFileProperty_FileLengthFrames, &size, &frames))
        try Self.check(ExtAudioFileSetProperty(opened, kExtAudioFileProperty_ClientDataFormat,
                                              UInt32(MemoryLayout<AudioStreamBasicDescription>.size), format.streamDescription))
        self.reference = opened
        self.format = format
        self.length = frames
        initialized = true
    }

    deinit { ExtAudioFileDispose(reference) }

    func seek(to frame: AVAudioFramePosition) throws { try Self.check(ExtAudioFileSeek(reference, frame)) }

    func read(into buffer: AVAudioPCMBuffer, frameCount: AVAudioFrameCount? = nil) throws {
        var count = frameCount ?? buffer.frameCapacity
        buffer.frameLength = count
        try Self.check(ExtAudioFileRead(reference, &count, buffer.mutableAudioBufferList))
        buffer.frameLength = count
    }

    private static func check(_ status: OSStatus) throws {
        if status != noErr { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}
