import XCTest
import AVFoundation
@testable import CoverFlow

final class KaraokeModelSelectorTests: XCTestCase {
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ModelSelector-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func defaults() -> UserDefaults {
        let name = "ModelSelectorTests." + UUID().uuidString, defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
    private func models(in root: URL) throws -> (KaraokeModel, KaraokeModel) {
        let checkpoint = root.appendingPathComponent("becruily_deux.ckpt"), yaml = root.appendingPathComponent("config_deux_becruily.yaml")
        try Data("fixture".utf8).write(to: checkpoint); try Data("fixture".utf8).write(to: yaml)
        let onnx = root.appendingPathComponent("Another MDX.onnx"), json = root.appendingPathComponent("Another MDX.json")
        try Data("fake onnx for configuration tests".utf8).write(to: onnx)
        try Data("{\"compensate\":1.01,\"mdx_dim_f_set\":2560,\"mdx_dim_t_set\":8,\"mdx_n_fft_scale_set\":5120,\"primary_stem\":\"Instrumental\"}".utf8).write(to: json)
        return (try KaraokeModel(checkpoint: checkpoint, configuration: yaml), try KaraokeModel(checkpoint: onnx, configuration: json))
    }
    private func wave(at path: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410)!
        buffer.frameLength = 4410
        for channel in 0..<2 { for index in 0..<4410 { buffer.floatChannelData![channel][index] = Float(sin(Double(index) * 0.07 + Double(channel))) * 0.1 } }
        try AVAudioFile(forWriting: path, settings: format.settings).write(from: buffer)
    }
    private func track(_ source: URL) -> Track {
        Track(id: UUID(), fileURL: source, title: "Song", artist: "Artist", albumTitle: "Album", albumArtist: nil,
              trackNumber: nil, discNumber: nil, duration: 0.1, year: nil, genre: nil, dateAdded: Date(),
              isDemo: false, missingMetadata: false, fingerprint: "fixture")
    }

    func testMDXConfigurationUsesModelFingerprintAndSupportsCustomParameters() throws {
        let root = try temporary(), (_, mdx) = try models(in: root)
        XCTAssertEqual(mdx.kind, .mdx)
        XCTAssertEqual(KaraokeModel.configuration(for: mdx.checkpoint), mdx.configuration)
        let parameters = try JSONSerialization.jsonObject(with: Data(contentsOf: mdx.configuration))
        let catalog = root.appendingPathComponent("catalog.json")
        try JSONSerialization.data(withJSONObject: [KaraokeModel.uvrHash(mdx.checkpoint): parameters]).write(to: catalog)
        let catalogModel = try KaraokeModel(checkpoint: mdx.checkpoint, configuration: catalog)
        XCTAssertEqual(catalogModel.kind, .mdx)
        try Data("{}".utf8).write(to: catalog)
        XCTAssertThrowsError(try KaraokeModel(checkpoint: mdx.checkpoint, configuration: catalog))
        var bad = parameters as! [String: Any]; bad["primary_stem"] = "Bass"
        try JSONSerialization.data(withJSONObject: bad).write(to: catalog)
        XCTAssertThrowsError(try KaraokeModel(checkpoint: mdx.checkpoint, configuration: catalog))
        bad = parameters as! [String: Any]; bad["mdx_dim_t_set"] = true
        try JSONSerialization.data(withJSONObject: bad).write(to: catalog)
        XCTAssertThrowsError(try KaraokeModel(checkpoint: mdx.checkpoint, configuration: catalog))
    }

    @MainActor
    func testSelectorPersistsMultipleModelsDeduplicatesAndMigratesOldPreference() throws {
        let root = try temporary(), (becruily, mdx) = try models(in: root), preferences = defaults()
        preferences.set(becruily.checkpoint.path, forKey: "karaoke.checkpoint")
        preferences.set(becruily.configuration.path, forKey: "karaoke.configuration")
        let store = KaraokeStore(directory: root, defaults: preferences)
        XCTAssertEqual(store.model, becruily)
        store.addModel(mdx); store.addModel(mdx)
        XCTAssertEqual(store.models.filter { $0.checkpoint == mdx.checkpoint }.count, 1)
        let managed = try XCTUnwrap(store.model)
        XCTAssertEqual(managed.checkpoint, mdx.checkpoint)
        XCTAssertNotEqual(managed.configuration, mdx.configuration)
        try FileManager.default.removeItem(at: mdx.configuration)
        let restored = KaraokeStore(directory: root, defaults: preferences)
        XCTAssertEqual(restored.model, managed)
        XCTAssertTrue(restored.models.contains(becruily))
        restored.selectModel(id: becruily.id)
        XCTAssertEqual(KaraokeStore(directory: root, defaults: preferences).model, becruily)
    }

    @MainActor
    func testSwitchingModelsUsesSeparateCachesAndRestoresPreviousPreparedAudio() throws {
        let root = try temporary(), (becruily, mdx) = try models(in: root), source = root.appendingPathComponent("source.wav")
        try wave(at: source)
        let track = track(source), preferences = defaults()
        let store = KaraokeStore(directory: root, model: becruily, defaults: preferences)
        store.addModel(mdx)
        let managed = try XCTUnwrap(store.model)
        for selected in [becruily, managed] {
            let key = try selected.cacheKey(trackID: track.id, source: source), folder = root.appendingPathComponent(key, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try wave(at: folder.appendingPathComponent("vocals.wav")); try wave(at: folder.appendingPathComponent("instrumental.wav"))
            let audio = KaraokeAudio(key: key, trackID: track.id, frames: 4410, sampleRate: 44100, modelSHA256: selected.kind.rawValue, directory: folder)
            try JSONEncoder().encode(audio).write(to: folder.appendingPathComponent("manifest.json"))
        }
        store.selectModel(id: becruily.id)
        store.refresh(for: track)
        let first = store.audio
        store.selectModel(id: managed.id)
        XCTAssertNotEqual(first?.key, store.audio?.key)
        XCTAssertEqual(store.audio?.modelSHA256, "mdx")
        store.selectModel(id: becruily.id)
        XCTAssertEqual(store.audio, first)
        XCTAssertFalse(store.isProcessing)
    }

    @MainActor
    func testModelCannotChangeWhilePreparationIsRunning() async throws {
        let root = try temporary(), (becruily, mdx) = try models(in: root), source = root.appendingPathComponent("source.wav")
        try wave(at: source)
        let store = KaraokeStore(directory: root, model: becruily, defaults: defaults())
        store.addModel(mdx)
        let managed = try XCTUnwrap(store.model)
        store.selectModel(id: becruily.id)
        store.prepare(track(source))
        XCTAssertTrue(store.isProcessing)
        store.selectModel(id: managed.id)
        XCTAssertEqual(store.model, becruily)
        store.cancel()
        for _ in 0..<500 where store.isProcessing { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(store.isProcessing)
    }

    @MainActor
    func testRealMDXModelThroughAutomaticPreparationWhenConfigured() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let resourcesPath = env["KARAOKE_TEST_RESOURCES"], let modelPath = env["KARAOKE_TEST_MDX_MODEL"] else {
            throw XCTSkip("Local MDX model integration not configured")
        }
        let resources = URL(fileURLWithPath: resourcesPath)
        let selected = try KaraokeModel(checkpoint: URL(fileURLWithPath: modelPath), configuration: resources.appendingPathComponent("Karaoke/mdx-model-data.json"))
        XCTAssertEqual(try KaraokeModel.uvrHash(selected.checkpoint), "cb790d0c913647ced70fc6b38f5bea1a")
        let root = try temporary(), source = root.appendingPathComponent("Song with spaces café.wav")
        try wave(at: source)
        let original = try Data(contentsOf: source), track = track(source)
        let runtime = KaraokeRuntime(python: resources.appendingPathComponent("KaraokeRuntime/python/bin/python3"),
            packages: resources.appendingPathComponent("KaraokeRuntime/site-packages"), helper: resources.appendingPathComponent("Karaoke/separate.py"))
        let store = KaraokeStore(directory: root, model: selected, defaults: defaults(), runtime: runtime)
        let finished = expectation(description: "MDX instrumental selected when ready")
        store.requestPlayback(.instrumental, for: track) { mode, audio in
            XCTAssertEqual(mode, .instrumental)
            XCTAssertEqual(audio?.frames, 4410)
            XCTAssertEqual(audio?.modelSHA256, "811cb24095d865763752310848b7ec86aeede0626cb05749ab35350e46897000")
            do { try audio?.validate() } catch { XCTFail("Invalid MDX output: \(error)") }
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 60)
        XCTAssertFalse(store.isProcessing)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.progress, 1)
        XCTAssertEqual(try Data(contentsOf: source), original)
    }
}
