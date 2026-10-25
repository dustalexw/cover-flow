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

    private let file: any PCMFrameSource
    private let targetFormat: AVAudioFormat
    private let converter: AVAudioConverter?
    private let input: AVAudioPCMBuffer
    private let totalOutputFrames: AVAudioFramePosition
    private var emittedFrames: AVAudioFramePosition = 0
    let duration: Double

    init(url: URL, start: Double = 0, sampleRate: Double = PCMDecoder.sampleRate) throws {
        guard sampleRate.isFinite, sampleRate > 0,
              let target = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        targetFormat = target
        file = try Self.open(url)
        guard file.length > 0 else { throw CocoaError(.fileReadCorruptFile) }
        let format = file.format
        duration = Double(file.length) / format.sampleRate
        let startFrame = min(file.length, max(0, AVAudioFramePosition(start * format.sampleRate)))
        if startFrame > 0 { try file.seek(to: startFrame) }
        totalOutputFrames = AVAudioFramePosition((Double(file.length - startFrame) * sampleRate / format.sampleRate).rounded())
        input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_192)!
        if format == target {
            converter = nil
        } else {
            guard let conversion = AVAudioConverter(from: format, to: target) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            // Normal priming removes resampler latency from the output. Disabling
            // priming would insert silent frames at sample-rate changes.
            conversion.primeMethod = .normal
            if format.channelCount == 1 { conversion.channelMap = [0, 0] }
            converter = conversion
        }
    }

    private static func open(_ url: URL) throws -> any PCMFrameSource {
        if OggOpusStream.isOgg(url) {
            do { return try OpusFileReader(url: url) } catch OggOpusError.notOpus {
                // Another Ogg codec: Core Audio reports whether it can read it.
            }
        }
        return try PCMFileReader(url: url)
    }

    func read() throws -> Chunk? {
        let remaining = totalOutputFrames - emittedFrames
        guard remaining > 0 else { return nil }
        let count = AVAudioFrameCount(min(AVAudioFramePosition(Self.chunkFrames), remaining))
        let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: count)!
        if let converter {
            var conversionError: NSError?
            var readError: Error?
            let status = converter.convert(to: output, error: &conversionError) { [file, input] _, status in
                do {
                    try file.read(into: input, frameCount: nil)
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

/// Deinterleaved Float32 frames at the file's own sample rate and channel count.
private protocol PCMFrameSource: AnyObject {
    var format: AVAudioFormat { get }
    var length: AVAudioFramePosition { get }
    func seek(to frame: AVAudioFramePosition) throws
    func read(into buffer: AVAudioPCMBuffer, frameCount: AVAudioFrameCount?) throws
}

/// The throwing Core Audio APIs also report damaged/unsupported files without
/// AVAudioFile's frame-position setter raising an Objective-C exception.
private final class PCMFileReader: PCMFrameSource {
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

/// Ogg Opus through Core Audio's Opus decoder, which handles mono and stereo. Core Audio
/// can't open Ogg files, so `OggOpusStream` supplies the packets, one per conversion.
private final class OpusFileReader: PCMFrameSource {
    let format: AVAudioFormat
    let length: AVAudioFramePosition
    private let stream: OggOpusStream
    private let gain: Float
    private var packets: OggOpusStream.PacketReader
    /// Granule position of the next packet's first sample.
    private var position: Int64
    /// Granule position of the next sample to return.
    private var next: Int64
    private var decoder: (converter: AVAudioConverter, input: AVAudioFormat, samples: Int)?
    private var pending: AVAudioPCMBuffer?
    private var pendingRange = 0..<0

    init(url: URL) throws {
        stream = try OggOpusStream(url: url)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(OpusPacket.sampleRate),
                                         channels: AVAudioChannelCount(stream.head.channels)) else {
            throw OggOpusError.damaged
        }
        self.format = format
        length = stream.length
        gain = stream.head.linearGain
        packets = stream.packets()
        position = stream.startGranule
        next = stream.origin
    }

    func seek(to frame: AVAudioFramePosition) throws {
        let target = stream.origin + min(max(0, frame), length)
        (packets, position) = stream.packets(toReach: target)
        next = target
        // Decoding restarts at the new packet, so the old decoder state no longer applies.
        decoder = nil
        pending = nil
        pendingRange = 0..<0
    }

    func read(into buffer: AVAudioPCMBuffer, frameCount: AVAudioFrameCount?) throws {
        let wanted = Int(min(frameCount ?? buffer.frameCapacity, buffer.frameCapacity))
        var filled = 0
        while filled < wanted {
            if pendingRange.isEmpty {
                guard next < stream.endGranule, try decodeNextPacket() else { break }
                continue
            }
            guard let source = pending?.floatChannelData, let destination = buffer.floatChannelData else { break }
            let count = min(wanted - filled, pendingRange.count)
            for channel in 0..<Int(format.channelCount) {
                let from = source[channel] + pendingRange.lowerBound
                let to = destination[channel] + filled
                if gain == 1 {
                    to.update(from: from, count: count)
                } else {
                    for k in 0..<count { to[k] = from[k] * gain }
                }
            }
            pendingRange = (pendingRange.lowerBound + count)..<pendingRange.upperBound
            filled += count
            next += Int64(count)
        }
        buffer.frameLength = AVAudioFrameCount(filled)
    }

    /// Decodes one packet and keeps its samples from `next` up to the end of the stream.
    /// Every packet is decoded, even one that is skipped, so the decoder state stays continuous.
    private func decodeNextPacket() throws -> Bool {
        guard let packet = packets.next() else { return false }
        guard let samples = OpusPacket.sampleCount(packet) else { throw OggOpusError.damaged }
        let start = position
        position += Int64(samples)
        let decoded = try decode(packet, samples: samples)
        let lower = max(start, next), upper = min(position, stream.endGranule)
        if lower < upper {
            pending = decoded
            pendingRange = Int(lower - start)..<Int(upper - start)
        }
        return true
    }

    private func decode(_ packet: [UInt8], samples: Int) throws -> AVAudioPCMBuffer {
        // The packet duration is part of Core Audio's Opus input format, so a stream
        // that changes frame size needs a new converter.
        if decoder?.samples != samples {
            var description = AudioStreamBasicDescription(
                mSampleRate: Double(OpusPacket.sampleRate), mFormatID: kAudioFormatOpus, mFormatFlags: 0,
                mBytesPerPacket: 0, mFramesPerPacket: UInt32(samples), mBytesPerFrame: 0,
                mChannelsPerFrame: format.channelCount, mBitsPerChannel: 0, mReserved: 0)
            guard let input = AVAudioFormat(streamDescription: &description),
                  let converter = AVAudioConverter(from: input, to: format) else {
                throw OggOpusError.decoderUnavailable
            }
            decoder = (converter, input, samples)
        }
        guard let decoder, let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples)) else {
            throw OggOpusError.decoderUnavailable
        }
        let compressed = AVAudioCompressedBuffer(format: decoder.input, packetCapacity: 1, maximumPacketSize: packet.count)
        packet.withUnsafeBytes { compressed.data.copyMemory(from: $0.baseAddress!, byteCount: packet.count) }
        compressed.byteLength = UInt32(packet.count)
        compressed.packetCount = 1
        compressed.packetDescriptions?.pointee = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.count))
        var supplied = false
        var conversionError: NSError?
        let status = decoder.converter.convert(to: output, error: &conversionError) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return compressed
        }
        if status == .error { throw conversionError ?? OggOpusError.damaged }
        // Core Audio's Opus decoder withholds the first 120 samples it produces, which lie
        // inside the pre-skip. Returning them as leading silence keeps every packet at its
        // coded length, so granule positions, and with them seeking, stay exact.
        let produced = Int(output.frameLength)
        if produced < samples, let channels = output.floatChannelData {
            for channel in 0..<Int(format.channelCount) {
                let data = channels[channel]
                if produced > 0 { memmove(data + (samples - produced), data, produced * MemoryLayout<Float>.stride) }
                data.update(repeating: 0, count: samples - produced)
            }
            output.frameLength = AVAudioFrameCount(samples)
        }
        return output
    }
}
