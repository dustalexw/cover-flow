import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor
final class KaraokeStore: ObservableObject {
    @Published private(set) var model: KaraokeModel?
    @Published private(set) var audio: KaraokeAudio?
    @Published private(set) var processingTrackID: UUID?
    @Published private(set) var processingTitle: String?
    @Published private(set) var stage = ""
    @Published private(set) var progress = 0.0
    @Published private(set) var requestedPlayback: KaraokePlayback?
    @Published var errorMessage: String?
    private let directory: URL
    private let runtimeOverride: KaraokeRuntime?
    private var track: Track?
    private var worker: Task<Void, Never>?
    private var process: KaraokeProcess?
    private var generation = UUID()
    private var playbackRequest: (trackID: UUID, apply: (KaraokePlayback, KaraokeAudio?) -> Void)?
    var isProcessing: Bool { processingTrackID != nil }

    init(directory: URL, model: KaraokeModel? = nil, defaults: UserDefaults = .standard, runtime: KaraokeRuntime? = nil) {
        self.directory = directory
        self.runtimeOverride = runtime
        if let model { self.model = model }
        else if let checkpoint = defaults.string(forKey: "karaoke.checkpoint"),
                let config = defaults.string(forKey: "karaoke.configuration"),
                let saved = try? KaraokeModel(checkpoint: URL(fileURLWithPath: checkpoint), configuration: URL(fileURLWithPath: config)) {
            self.model = saved
        } else { self.model = KaraokeModel.discover() }
    }

    func refresh(for track: Track?) {
        if playbackRequest?.trackID != track?.id { clearPlaybackRequest() }
        self.track = track; audio = nil
        guard let track, let model, let key = try? model.cacheKey(trackID: track.id, source: track.fileURL) else { return }
        let folder = directory.appendingPathComponent(key, isDirectory: true)
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
              var saved = try? JSONDecoder().decode(KaraokeAudio.self, from: data),
              saved.key == key, saved.trackID == track.id else { return }
        saved.directory = folder
        guard (try? saved.validate()) != nil else { return }
        audio = saved
    }

    /// Last click wins while both stems are prepared together. Original clears the
    /// pending switch but leaves useful preparation running in the background.
    func requestPlayback(_ mode: KaraokePlayback, for track: Track,
                         apply: @escaping (KaraokePlayback, KaraokeAudio?) -> Void) {
        errorMessage = nil
        if mode == .original {
            clearPlaybackRequest(); apply(.original, nil); return
        }
        guard !isProcessing || processingTrackID == track.id else {
            errorMessage = "Already preparing \(processingTitle ?? "another track"). Wait for it to finish, or cancel preparation first."
            return
        }
        refresh(for: track)
        if let audio {
            clearPlaybackRequest(); apply(mode, audio); return
        }
        if model == nil { chooseModel() }
        guard model != nil else { return }
        if let audio {
            clearPlaybackRequest(); apply(mode, audio); return
        }
        playbackRequest = (track.id, apply); requestedPlayback = mode
        if !isProcessing { prepare(track) }
    }

    private func clearPlaybackRequest() {
        playbackRequest = nil; requestedPlayback = nil
    }

    func chooseModel() {
        guard !isProcessing else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose Becruily Deux model"
        panel.message = "Choose becruily_deux.ckpt. Its matching configuration can be selected next if needed."
        panel.allowedContentTypes = [UTType(filenameExtension: "ckpt") ?? .data]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let checkpoint = panel.url else { return }
        var configuration = checkpoint.deletingLastPathComponent().appendingPathComponent("config_deux_becruily.yaml")
        if !FileManager.default.fileExists(atPath: configuration.path) {
            let configPanel = NSOpenPanel()
            configPanel.title = "Choose model configuration"
            configPanel.message = "Choose the YAML configuration that came with this checkpoint."
            configPanel.allowedContentTypes = [UTType(filenameExtension: "yaml") ?? .text, UTType(filenameExtension: "yml") ?? .text]
            guard configPanel.runModal() == .OK, let selected = configPanel.url else { return }
            configuration = selected
        }
        do {
            model = try KaraokeModel(checkpoint: checkpoint, configuration: configuration)
            UserDefaults.standard.set(checkpoint.path, forKey: "karaoke.checkpoint")
            UserDefaults.standard.set(configuration.path, forKey: "karaoke.configuration")
            errorMessage = nil; refresh(for: track)
        } catch { errorMessage = error.localizedDescription }
    }

    func prepare(_ track: Track) {
        guard !isProcessing else { return }
        errorMessage = nil
        refresh(for: track)
        if audio != nil { stage = "Ready — saved karaoke audio"; return }
        guard let model else { errorMessage = "Choose the Becruily Deux model and its configuration first."; return }
        let token = UUID(); generation = token
        processingTrackID = track.id; processingTitle = track.title
        stage = "Preparing audio…"; progress = 0
        let processor = KaraokeProcess(); process = processor
        let progressTarget = KaraokeProgressTarget(store: self, token: token)
        let base = directory
        let runtimeOverride = runtimeOverride
        worker = Task { [weak self] in
            do {
                let result = try await withTaskCancellationHandler {
                    try await Task.detached(priority: .userInitiated) {
                        let key = try model.cacheKey(trackID: track.id, source: track.fileURL)
                        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
                        let job = base.appendingPathComponent(".job-" + token.uuidString, isDirectory: true)
                        try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
                        defer { try? FileManager.default.removeItem(at: job) }
                        let input = job.appendingPathComponent("source.wav")
                        let frames = try await KaraokePreparation.decode(source: track.fileURL, to: input, checkCancellation: { try processor.checkCancellation() })
                        try Task.checkCancellation()
                        try processor.checkCancellation()
                        let runtime = try runtimeOverride ?? KaraokeRuntime.bundled()
                        let event = try processor.run(runtime: runtime, model: model, input: input, output: job) { event in
                            progressTarget.send(event)
                        }
                        try Task.checkCancellation()
                        try processor.checkCancellation()
                        guard event.frames == frames, event.sample_rate == 44_100,
                              let modelHash = event.model_sha256, modelHash.count == 64,
                              try model.cacheKey(trackID: track.id, source: track.fileURL) == key else {
                            throw KaraokeError.message("The source or model changed while processing. Prepare the track again.")
                        }
                        let finished = base.appendingPathComponent(key, isDirectory: true)
                        var audio = KaraokeAudio(key: key, trackID: track.id, frames: frames, sampleRate: 44_100,
                                                 modelSHA256: modelHash, directory: job)
                        try audio.validate()
                        try FileManager.default.removeItem(at: input)
                        if FileManager.default.fileExists(atPath: finished.path) { try FileManager.default.removeItem(at: finished) }
                        try FileManager.default.moveItem(at: job, to: finished)
                        audio.directory = finished
                        do { try JSONEncoder().encode(audio).write(to: finished.appendingPathComponent("manifest.json"), options: .atomic) }
                        catch { try? FileManager.default.removeItem(at: finished); throw error }
                        return audio
                    }.value
                } onCancel: { processor.cancel() }
                guard let self, self.generation == token else { return }
                if self.track?.id == track.id { self.audio = result }
                self.stage = "Ready — karaoke audio saved"; self.progress = 1
                if self.track?.id == track.id, let request = self.playbackRequest,
                   request.trackID == track.id, let mode = self.requestedPlayback {
                    self.clearPlaybackRequest()
                    request.apply(mode, result)
                }
            } catch {
                guard let self, self.generation == token else { return }
                if error is CancellationError { self.stage = "Cancelled" }
                else { self.errorMessage = error.localizedDescription; self.stage = "Couldn’t prepare karaoke" }
            }
            guard let self, self.generation == token else { return }
            self.clearPlaybackRequest()
            self.processingTrackID = nil; self.processingTitle = nil; self.worker = nil; self.process = nil
        }
    }

    func cancel() {
        clearPlaybackRequest()
        process?.cancel(); worker?.cancel()
    }

    fileprivate func receive(_ event: KaraokeProgress, token: UUID) {
        guard generation == token else { return }
        stage = event.stage; progress = event.progress.clamped(0, 1)
    }

    func exportInstrumental(title: String) {
        guard let audio else { return }
        let panel = NSSavePanel()
        panel.title = "Export karaoke instrumental"
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = title.replacingOccurrences(of: "/", with: "-") + " — Karaoke.wav"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try audio.validate()
            guard destination.standardizedFileURL != audio.instrumental.standardizedFileURL,
                  destination.standardizedFileURL != track?.fileURL.standardizedFileURL else {
                throw KaraokeError.message("Choose a different filename so the original audio stays unchanged.")
            }
            let temporary = destination.deletingLastPathComponent().appendingPathComponent(".karaoke-export-" + UUID().uuidString + ".wav")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try FileManager.default.copyItem(at: audio.instrumental, to: temporary)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else { try FileManager.default.moveItem(at: temporary, to: destination) }
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }
}

@MainActor
private final class KaraokeProgressTarget {
    weak var store: KaraokeStore?
    let token: UUID
    init(store: KaraokeStore, token: UUID) { self.store = store; self.token = token }
    nonisolated func send(_ event: KaraokeProgress) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            store?.receive(event, token: token)
        }
    }
}
