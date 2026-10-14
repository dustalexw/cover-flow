import XCTest
import AVFoundation
import AppKit
@testable import CoverFlow

final class KaraokeTests: XCTestCase {
    func testPlaybackShortcutsDoNotCaptureMenuCombinations() throws {
        func event(_ text: String, key: UInt16 = 0, flags: NSEvent.ModifierFlags = [], repeating: Bool = false) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: 0, context: nil, characters: text,
                charactersIgnoringModifiers: text, isARepeat: repeating, keyCode: key))
        }
        // Physical Space is reliable even when the focused control supplies no character.
        XCTAssertEqual(KaraokeShortcut(event: try event("", key: 49)), .playPause)
        XCTAssertEqual(KaraokeShortcut(event: try event("1")), .original)
        XCTAssertEqual(KaraokeShortcut(event: try event("2")), .instrumental)
        XCTAssertEqual(KaraokeShortcut(event: try event("3")), .vocals)
        XCTAssertEqual(KaraokeShortcut(event: try event("p")), .prepare)
        XCTAssertEqual(KaraokeShortcut(event: try event("P", flags: .capsLock)), .prepare)
        for flags: NSEvent.ModifierFlags in [.command, .option, .control, .shift] {
            XCTAssertNil(KaraokeShortcut(event: try event("", key: 49, flags: flags)))
            XCTAssertNil(KaraokeShortcut(event: try event("1", flags: flags)))
            XCTAssertNil(KaraokeShortcut(event: try event("p", flags: flags)))
        }
        XCTAssertNil(KaraokeShortcut(event: try event("4")))
        XCTAssertNil(KaraokeShortcut(event: try event("f")))
        // Repeats remain recognizable so the window swallows them without toggling again.
        XCTAssertEqual(KaraokeShortcut(event: try event(" ", key: 49, repeating: true)), .playPause)
    }

    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("KaraokeTests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func model(in root: URL) throws -> KaraokeModel {
        let checkpoint = root.appendingPathComponent("becruily_deux.ckpt"), config = root.appendingPathComponent("config_deux_becruily.yaml")
        try Data("fixture".utf8).write(to: checkpoint)
        try Data("audio: {sample_rate: 44100}".utf8).write(to: config)
        return try KaraokeModel(checkpoint: checkpoint, configuration: config)
    }
    private func wave(at url: URL, frames: AVAudioFrameCount = 4410, sampleRate: Double = 44100) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<2 {
            for i in 0..<Int(frames) { buffer.floatChannelData![channel][i] = Float(sin(Double(i) * 0.07)) * 0.1 }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private func track(for source: URL) -> Track {
        Track(id: UUID(), fileURL: source, title: "Song", artist: "Artist", albumTitle: "Album", albumArtist: nil,
              trackNumber: nil, discNumber: nil, duration: 0.1, year: nil, genre: nil, dateAdded: Date(),
              isDemo: false, missingMetadata: false, fingerprint: "fixture")
    }

    func testDiscoveryAndModelValidation() throws {
        let downloads = try temporary(), directory = downloads.appendingPathComponent("Otras")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let expected = try model(in: directory)
        XCTAssertEqual(KaraokeModel.discover(in: downloads), expected)
        try FileManager.default.removeItem(at: expected.configuration)
        XCTAssertNil(KaraokeModel.discover(in: downloads))
        XCTAssertThrowsError(try KaraokeModel(checkpoint: expected.checkpoint, configuration: expected.configuration))
    }

    func testCacheKeyChangesWhenSourceOrConfigurationChanges() throws {
        let root = try temporary(), selected = try model(in: root), id = UUID(), source = root.appendingPathComponent("source.wav")
        try wave(at: source)
        let key = try selected.cacheKey(trackID: id, source: source)
        XCTAssertEqual(key, try selected.cacheKey(trackID: id, source: source))
        XCTAssertNotEqual(key, try selected.cacheKey(trackID: UUID(), source: source))
        try Data("audio: {sample_rate: 44100}\nchanged: true".utf8).write(to: selected.configuration)
        XCTAssertNotEqual(key, try selected.cacheKey(trackID: id, source: source))
        let changed = try selected.cacheKey(trackID: id, source: source)
        try wave(at: source, frames: 8820)
        XCTAssertNotEqual(changed, try selected.cacheKey(trackID: id, source: source))
    }

    func testPreparationResamplesWithoutChangingSource() async throws {
        let root = try temporary(), source = root.appendingPathComponent("source.wav"), decoded = root.appendingPathComponent("prepared.wav")
        try wave(at: source, frames: 4800, sampleRate: 48000)
        let original = try Data(contentsOf: source)
        let frames = try await KaraokePreparation.decode(source: source, to: decoded)
        XCTAssertEqual(frames, 4410)
        let output = try AVAudioFile(forReading: decoded)
        XCTAssertEqual(output.fileFormat.sampleRate, 44100)
        XCTAssertEqual(output.fileFormat.channelCount, 2)
        XCTAssertEqual(output.length, frames)
        XCTAssertEqual(original, try Data(contentsOf: source))
    }

    func testPreparationCanCancelBeforeWritingAudio() async throws {
        let root = try temporary(), source = root.appendingPathComponent("source.wav")
        try wave(at: source)
        do {
            _ = try await KaraokePreparation.decode(source: source, to: root.appendingPathComponent("cancelled.wav"),
                                                     checkCancellation: { throw CancellationError() })
            XCTFail("Cancellation was ignored")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testSavedAudioRequiresMatchingStemLengths() throws {
        let root = try temporary()
        try wave(at: root.appendingPathComponent("instrumental.wav"))
        try wave(at: root.appendingPathComponent("vocals.wav"))
        let audio = KaraokeAudio(key: "key", trackID: UUID(), frames: 4410, sampleRate: 44100, modelSHA256: "sha", directory: root)
        XCTAssertNoThrow(try audio.validate())
        XCTAssertNil(audio.url(for: .original))
        XCTAssertEqual(audio.url(for: .instrumental), audio.instrumental)
        try wave(at: audio.vocals, frames: 2205)
        XCTAssertThrowsError(try audio.validate())
    }

    func testProcessCanCancelBeforeLaunch() throws {
        let root = try temporary(), selected = try model(in: root)
        let process = KaraokeProcess(); process.cancel()
        let runtime = KaraokeRuntime(python: URL(fileURLWithPath: "/usr/bin/python3"), packages: root, helper: root.appendingPathComponent("missing.py"))
        XCTAssertThrowsError(try process.run(runtime: runtime, model: selected, input: root, output: root, progress: { _ in })) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    @MainActor
    func testCacheReloadDoesNotTrustIncompleteAudioAndInvalidatesChangedSource() throws {
        let root = try temporary(), selected = try model(in: root), source = root.appendingPathComponent("source.wav")
        try wave(at: source)
        let track = Track(id: UUID(), fileURL: source, title: "Song", artist: "Artist", albumTitle: "Album", albumArtist: nil,
                          trackNumber: nil, discNumber: nil, duration: 0.1, year: nil, genre: nil, dateAdded: Date(),
                          isDemo: false, missingMetadata: false, fingerprint: "fixture")
        let key = try selected.cacheKey(trackID: track.id, source: source)
        let folder = root.appendingPathComponent(key, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try wave(at: folder.appendingPathComponent("instrumental.wav"))
        try wave(at: folder.appendingPathComponent("vocals.wav"))
        let audio = KaraokeAudio(key: key, trackID: track.id, frames: 4410, sampleRate: 44100, modelSHA256: "hash", directory: folder)
        try JSONEncoder().encode(audio).write(to: folder.appendingPathComponent("manifest.json"))
        let store = KaraokeStore(directory: root, model: selected)
        store.refresh(for: track)
        XCTAssertEqual(store.audio, audio)
        var applied: [KaraokePlayback] = []
        for mode: KaraokePlayback in [.instrumental, .vocals, .original] {
            store.requestPlayback(mode, for: track) { selected, stems in
                applied.append(selected)
                XCTAssertEqual(stems, selected == .original ? nil : audio)
            }
        }
        XCTAssertEqual(applied, [.instrumental, .vocals, .original])
        XCTAssertNil(store.requestedPlayback)
        store.prepare(track)  // A valid cache hit never launches a processor.
        XCTAssertFalse(store.isProcessing)
        try FileManager.default.removeItem(at: audio.vocals)
        store.refresh(for: track)
        XCTAssertNil(store.audio)
        try wave(at: audio.vocals)
        try wave(at: source, frames: 8820)
        store.refresh(for: track)
        XCTAssertNil(store.audio)
    }

    @MainActor
    func testOriginalOrTrackChangeCancelsPendingAutomaticSwitch() async throws {
        for returnToOriginal in [true, false] {
            let root = try temporary(), selected = try model(in: root), source = root.appendingPathComponent("source.wav")
            try wave(at: source)
            let track = track(for: source), store = KaraokeStore(directory: root, model: selected)
            var applied: [KaraokePlayback] = []
            store.requestPlayback(.instrumental, for: track) { mode, _ in applied.append(mode) }
            XCTAssertTrue(store.isProcessing)
            XCTAssertEqual(store.requestedPlayback, .instrumental)
            if returnToOriginal {
                store.requestPlayback(.original, for: track) { mode, _ in applied.append(mode) }
            } else {
                store.refresh(for: nil)
            }
            XCTAssertNil(store.requestedPlayback)
            store.cancel()
            for _ in 0..<500 where store.isProcessing { try await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertFalse(store.isProcessing)
            XCTAssertEqual(applied, returnToOriginal ? [.original] : [])
            XCTAssertNil(store.errorMessage)
        }
    }

    @MainActor
    func testAutomaticPreparationSwitchesToLatestChoiceWhenReady() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let resourcesPath = environment["KARAOKE_TEST_RESOURCES"], let modelPath = environment["KARAOKE_TEST_MODEL_DIR"] else {
            throw XCTSkip("Local model integration not configured")
        }
        let resources = URL(fileURLWithPath: resourcesPath), modelDirectory = URL(fileURLWithPath: modelPath)
        let selected = try KaraokeModel(checkpoint: modelDirectory.appendingPathComponent("becruily_deux.ckpt"),
                                        configuration: modelDirectory.appendingPathComponent("config_deux_becruily.yaml"))
        let runtime = KaraokeRuntime(python: resources.appendingPathComponent("KaraokeRuntime/python/bin/python3"),
                                     packages: resources.appendingPathComponent("KaraokeRuntime/site-packages"),
                                     helper: resources.appendingPathComponent("Karaoke/separate.py"))
        let root = try temporary(), source = root.appendingPathComponent("source.wav")
        try wave(at: source)
        let original = try Data(contentsOf: source), track = track(for: source)
        let store = KaraokeStore(directory: root, model: selected, runtime: runtime)
        let ready = expectation(description: "Latest requested mode applied after preparation")
        store.requestPlayback(.instrumental, for: track) { _, _ in XCTFail("Superseded mode applied") }
        XCTAssertTrue(store.isProcessing)
        store.requestPlayback(.vocals, for: track) { mode, audio in
            XCTAssertEqual(mode, .vocals)
            XCTAssertEqual(audio?.trackID, track.id)
            XCTAssertEqual(audio?.frames, 4410)
            do { try audio?.validate() } catch { XCTFail("Invalid prepared audio: \(error)") }
            ready.fulfill()
        }
        XCTAssertEqual(store.requestedPlayback, .vocals)
        await fulfillment(of: [ready], timeout: 45)
        XCTAssertFalse(store.isProcessing)
        XCTAssertNil(store.requestedPlayback)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.progress, 1)
        XCTAssertEqual(try Data(contentsOf: source), original)
        XCTAssertNotNil(store.audio)
    }

    func testLiveProcessCancellationStopsWorkerPromptly() async throws {
        let root = try temporary(), selected = try model(in: root), python = URL(fileURLWithPath: "/usr/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path) else { throw XCTSkip("System Python unavailable") }
        let helper = root.appendingPathComponent("wait.py")
        try Data("import time\nprint('{\"stage\":\"Working\",\"progress\":0}',flush=True)\ntime.sleep(60)\n".utf8).write(to: helper)
        let runtime = KaraokeRuntime(python: python, packages: root, helper: helper), process = KaraokeProcess()
        let began = expectation(description: "Worker started")
        let task = Task.detached {
            try process.run(runtime: runtime, model: selected, input: root, output: root) { event in
                if event.stage == "Working" { began.fulfill() }
            }
        }
        await fulfillment(of: [began], timeout: 10)
        let start = Date()
        process.cancel()
        do { _ = try await task.value; XCTFail("Worker ignored cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testPackagedProcessorWithLocalModelWhenConfigured() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let resourcesPath = environment["KARAOKE_TEST_RESOURCES"], let modelPath = environment["KARAOKE_TEST_MODEL_DIR"] else {
            throw XCTSkip("Local model integration is enabled with KARAOKE_TEST_RESOURCES and KARAOKE_TEST_MODEL_DIR")
        }
        let resources = URL(fileURLWithPath: resourcesPath), selectedDirectory = URL(fileURLWithPath: modelPath)
        let selected = try KaraokeModel(checkpoint: selectedDirectory.appendingPathComponent("becruily_deux.ckpt"),
                                        configuration: selectedDirectory.appendingPathComponent("config_deux_becruily.yaml"))
        let root = try temporary(), source = root.appendingPathComponent("Song with spaces café.wav"), input = root.appendingPathComponent("prepared.wav")
        try wave(at: source, frames: 48000, sampleRate: 48000)
        let before = try Data(contentsOf: source)
        let frames = try await KaraokePreparation.decode(source: source, to: input)
        let runtime = KaraokeRuntime(python: resources.appendingPathComponent("KaraokeRuntime/python/bin/python3"),
                                    packages: resources.appendingPathComponent("KaraokeRuntime/site-packages"),
                                    helper: resources.appendingPathComponent("Karaoke/separate.py"))
        let event = try await Task.detached {
            try KaraokeProcess().run(runtime: runtime, model: selected, input: input, output: root, progress: { _ in })
        }.value
        XCTAssertEqual(event.frames, frames)
        XCTAssertEqual(event.sample_rate, 44100)
        XCTAssertEqual(event.model_sha256, "10255c02295bf3e3865d4ee50ff752d7b19b124ed5fd93b147babc4333eda3aa")
        let audio = KaraokeAudio(key: "integration", trackID: UUID(), frames: frames, sampleRate: 44100,
                                 modelSHA256: event.model_sha256!, directory: root)
        XCTAssertNoThrow(try audio.validate())
        XCTAssertEqual(before, try Data(contentsOf: source))
    }
}
