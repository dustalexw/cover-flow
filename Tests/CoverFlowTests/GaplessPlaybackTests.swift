import AVFoundation
import XCTest
@testable import CoverFlow

final class GaplessPlaybackTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func fixture(_ name: String, rate: Double = 48_000, channels: AVAudioChannelCount = 2,
                         seconds: Double = 0.2, value: Float = 0.25, frequency: Double = 0) throws -> URL {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let count = AVAudioFrameCount(rate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
        buffer.frameLength = count
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(count) { buffer.floatChannelData![channel][frame] = frequency == 0 ? value : value * Float(sin(Double(frame) * 2 * .pi * frequency / rate)) }
        }
        let url = directory.appendingPathComponent(name + ".caf")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    func testStemMixChangesImmediatelyAndPreservesClockAndSeek() throws {
        try requireAudioComponents()
        let completed = expectation(description: "Live stem mix")
        Task { @MainActor in
            do {
                let source = AudioSource(index: 0, trackID: UUID(), url: try fixture("clock", seconds: 4, value: 0.9),
                                         stemFiles: [.drums: try fixture("drums", seconds: 4, value: 0.1),
                                                     .vocals: try fixture("vocals", seconds: 4, value: 0.2)])
                let player = GaplessAudioPlayer()
                player.volume = 0.01
                player.visualizerAudio.setEnabled(true)
                player.onFailure = { _, error in XCTFail(error.localizedDescription) }
                var mix = StemMixSettings(); mix.muted = [.vocals]
                player.setStemMix(mix)
                player.load(source, autoplay: true)
                defer { player.stop() }
                @MainActor func level() -> Float {
                    var values = Array(repeating: Float(0), count: 8192)
                    let frames = values.withUnsafeMutableBufferPointer { player.visualizerAudio.drain(into: $0) }
                    return values.prefix(frames * 2).map(abs).max() ?? 0
                }
                try await Task.sleep(for: .milliseconds(700))
                let drums = level()
                XCTAssertGreaterThan(drums, 0)
                let before = player.currentTime
                mix.muted = [.drums]
                player.setStemMix(mix)
                try await Task.sleep(for: .milliseconds(150))
                _ = level() // discard the transition in the tap ring
                try await Task.sleep(for: .milliseconds(150))
                XCTAssertEqual(level(), drums * 2, accuracy: max(0.0001, drums * 0.05))
                player.synchronize()
                XCTAssertGreaterThan(player.currentTime, before)
                player.pause()
                player.seek(to: 1.5)
                try await Task.sleep(for: .milliseconds(200))
                XCTAssertFalse(player.isPlaying)
                XCTAssertEqual(player.currentTime, 1.5, accuracy: 0.001)
                player.play()
                try await Task.sleep(for: .milliseconds(350))
                XCTAssertEqual(level(), drums * 2, accuracy: max(0.0001, drums * 0.05))
                XCTAssertTrue(player.isPlaying)
            } catch { XCTFail(error.localizedDescription) }
            completed.fulfill()
        }
        wait(for: [completed], timeout: 15)
    }

    func testStemNodesRemainPhaseAlignedAfterPauseAndSeek() throws {
        try requireAudioComponents()
        let completed = expectation(description: "Phase-aligned stems")
        Task { @MainActor in
            do {
                let positive = try fixture("positive", seconds: 4, value: 0.2, frequency: 440)
                let negative = try fixture("negative", seconds: 4, value: -0.2, frequency: 440)
                let player = GaplessAudioPlayer(); player.volume = 0.01
                player.visualizerAudio.setEnabled(true)
                player.onFailure = { _, error in XCTFail(error.localizedDescription) }
                player.load(AudioSource(index: 0, trackID: UUID(), url: positive,
                                        stemFiles: [.drums: positive, .bass: negative]), autoplay: true)
                defer { player.stop() }
                @MainActor func checkCancellation() {
                    var values = Array(repeating: Float(0), count: 8192)
                    let frames = values.withUnsafeMutableBufferPointer { player.visualizerAudio.drain(into: $0) }
                    XCTAssertGreaterThan(frames, 0)
                    XCTAssertLessThan(values.prefix(frames * 2).map(abs).max() ?? 0, 0.000001,
                                      "Opposite stems must cancel; misaligned nodes create a tone.")
                }
                try await Task.sleep(for: .milliseconds(600)); checkCancellation()
                player.pause()
                try await Task.sleep(for: .milliseconds(80)); player.play()
                try await Task.sleep(for: .milliseconds(300)); checkCancellation()
                player.seek(to: 1.5)
                try await Task.sleep(for: .milliseconds(400)); checkCancellation()
            } catch { XCTFail(error.localizedDescription) }
            completed.fulfill()
        }
        wait(for: [completed], timeout: 15)
    }

    func testRenderedTrackBoundariesHaveNoInsertedSilence() async throws {
        try requireAudioComponents()
        let urls = try [fixture("first"), fixture("mono44100", rate: 44_100, channels: 1),
                        fixture("stereo96000", rate: 96_000), fixture("last", value: 0.5)]
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: PCMDecoder.outputFormat)
        let visualizerAudio = VisualizerAudioBuffer()
        visualizerAudio.setEnabled(true)
        node.installTap(onBus: 0, bufferSize: 1024, format: PCMDecoder.outputFormat) { buffer, _ in
            guard let channels = buffer.floatChannelData else { return }
            visualizerAudio.append(left: channels[0], right: channels[1], frames: Int(buffer.frameLength))
        }
        try engine.enableManualRenderingMode(.offline, format: PCMDecoder.outputFormat, maximumFrameCount: 1_024)
        var boundaries: [Int] = [0]
        var frames = 0
        for url in urls {
            let decoder = try PCMDecoder(url: url)
            while let chunk = try await decoder.read() {
                node.scheduleBuffer(chunk.buffer, completionCallbackType: .dataPlayedBack, completionHandler: nil)
                frames += Int(chunk.buffer.frameLength)
            }
            boundaries.append(frames)
        }
        XCTAssertEqual(boundaries, [0, 9_600, 19_200, 28_800, 38_400])
        try engine.start()
        node.play()
        defer { engine.stop() }
        let output = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 1_024)!
        var samples: [Float] = []
        while samples.count < frames {
            let count = AVAudioFrameCount(min(1_024, frames - samples.count))
            let status = try engine.renderOffline(count, to: output)
            XCTAssertEqual(status, .success)
            samples.append(contentsOf: UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
        }
        var tapped = Array(repeating: Float(0), count: 8192)
        let tappedFrames = tapped.withUnsafeMutableBufferPointer { visualizerAudio.drain(into: $0) }
        XCTAssertGreaterThan(tappedFrames, 0)
        XCTAssertTrue(tapped.prefix(tappedFrames * 2).contains { abs($0) > 0.15 })
        // A constant signal makes even one inserted zero frame observable.
        for boundary in boundaries.dropFirst().dropLast() {
            for frame in (boundary - 64)..<(boundary + 64) {
                XCTAssertGreaterThan(abs(samples[frame]), 0.15, "Silence at boundary frame \(frame)")
            }
        }
        XCTAssertEqual(samples[30_000], 0.5, accuracy: 0.001)
    }

    func testSeekDecodesOnlyRemainingFramesAndBoundsMemory() async throws {
        // Resampling needs the same Core Audio access as the other decoder checks,
        // including when the Intel test bundle runs under Rosetta.
        try requireAudioComponents()
        let decoder = try PCMDecoder(url: fixture("long", rate: 44_100, channels: 1, seconds: 3), start: 1.25)
        var frames = 0
        var lastCount = 0
        while let chunk = try await decoder.read() {
            XCTAssertLessThanOrEqual(chunk.buffer.frameCapacity, PCMDecoder.chunkFrames)
            frames += Int(chunk.buffer.frameLength)
            if chunk.isLast { lastCount += 1 }
        }
        XCTAssertEqual(frames, 84_000)
        XCTAssertEqual(lastCount, 1)
    }

    func testCompressedFilesRespectDecodedFrameCounts() async throws {
        try requireAudioComponents()
        for name in ["tone-aac.m4a", "tone-alac.m4a", "tone.flac", "tone.mp3"] {
            let url = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/" + name)
            let decoder = try PCMDecoder(url: url)
            var frames = 0
            while let chunk = try await decoder.read() { frames += Int(chunk.buffer.frameLength) }
            XCTAssertEqual(frames, 48_000, "Codec delay or padding leaked into \(name)")
        }
    }

    private func requireAudioComponents() throws {
        var description = AudioComponentDescription(componentType: kAudioUnitType_Generator,
            componentSubType: kAudioUnitSubType_ScheduledSoundPlayer, componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard AudioComponentFindNext(nil, &description) != nil else {
            throw XCTSkip("The test environment cannot access macOS audio components.")
        }
    }

    func testPlaybackOrderIncludesGaplessRepeatAndManualSkip() {
        XCTAssertEqual(PlaybackOrder.successor(after: 0, count: 3, repeatMode: .off), 1)
        XCTAssertNil(PlaybackOrder.successor(after: 2, count: 3, repeatMode: .off))
        XCTAssertEqual(PlaybackOrder.successor(after: 2, count: 3, repeatMode: .all), 0)
        XCTAssertEqual(PlaybackOrder.successor(after: 1, count: 3, repeatMode: .one), 1)
        XCTAssertEqual(PlaybackOrder.successor(after: 1, count: 3, repeatMode: .one, automatic: false), 2)
        XCTAssertNil(PlaybackOrder.successor(after: 0, count: 0, repeatMode: .all))
    }

    func testLiveTransitionsPauseSeekAndEndOfQueue() throws {
        try requireAudioComponents()
        let completed = expectation(description: "Playback checks completed")
        Task { @MainActor in
            do {
                let first = AudioSource(index: 0, trackID: UUID(), url: try fixture("liveA", seconds: 0.4))
                let second = AudioSource(index: 1, trackID: UUID(), url: try fixture("liveB", rate: 44_100, channels: 1, seconds: 0.4))
                let player = GaplessAudioPlayer()
                player.volume = 0
                player.nextSource = { $0 == first ? second : nil }
                var transitions: [AudioSource] = []
                var ended = false
                player.onTrackChanged = { source, _, _ in transitions.append(source) }
                player.onEnd = { ended = true }
                player.onFailure = { _, error in XCTFail(error.localizedDescription) }
                player.load(first, autoplay: false)
                try await Task.sleep(for: .milliseconds(200))
                XCTAssertFalse(player.isPlaying)
                XCTAssertEqual(player.currentTime, 0)
                player.play()
                try await Task.sleep(for: .milliseconds(150))
                player.pause()
                let paused = player.currentTime
                try await Task.sleep(for: .milliseconds(150))
                XCTAssertEqual(player.currentTime, paused, accuracy: 0.04)
                player.seek(to: 0.2)
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertFalse(player.isPlaying)
                XCTAssertEqual(player.currentTime, 0.2, accuracy: 0.001)
                transitions = []
                player.play()
                try await Task.sleep(for: .milliseconds(850))
                XCTAssertEqual(transitions.map(\.trackID), [second.trackID])
                XCTAssertTrue(ended)
                XCTAssertFalse(player.isPlaying)
                player.stop()

            } catch { XCTFail(error.localizedDescription) }
            completed.fulfill()
        }
        wait(for: [completed], timeout: 10)
    }

    func testQueueEditInvalidatesPreparedAndInFlightTracks() throws {
        try requireAudioComponents()
        let completed = expectation(description: "Playback checks completed")
        Task { @MainActor in
            do {
                let first = AudioSource(index: 0, trackID: UUID(), url: try fixture("editA", seconds: 0.4))
                let removed = AudioSource(index: 1, trackID: UUID(), url: try fixture("editB", seconds: 0.4))
                let replacement = AudioSource(index: 1, trackID: UUID(), url: try fixture("editC", seconds: 0.4))
                let player = GaplessAudioPlayer()
                player.volume = 0
                var next = removed
                player.nextSource = { $0 == first ? next : nil }
                var played: [UUID] = []
                player.onTrackChanged = { source, _, _ in played.append(source.trackID) }
                player.load(first, autoplay: false)
                try await Task.sleep(for: .milliseconds(150))
                next = replacement
                player.refreshUpcoming(current: first)
                player.play()
                try await Task.sleep(for: .milliseconds(1_000))
                XCTAssertTrue(played.contains(replacement.trackID))
                XCTAssertFalse(played.contains(removed.trackID))
                player.stop()
                // Edit immediately, while initial decoding is still in flight.
                next = removed
                player.load(first, autoplay: false)
                next = replacement
                player.refreshUpcoming(current: first)
                played = []
                player.play()
                try await Task.sleep(for: .milliseconds(1_000))
                XCTAssertTrue(played.contains(replacement.trackID))
                XCTAssertFalse(played.contains(removed.trackID))
                player.stop()

            } catch { XCTFail(error.localizedDescription) }
            completed.fulfill()
        }
        wait(for: [completed], timeout: 10)
    }


}
