import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor
final class KaraokeStore: ObservableObject {
    @Published private(set) var model: KaraokeModel?
    @Published private(set) var models: [KaraokeModel] = []
    @Published private(set) var audio: KaraokeAudio?
    @Published private(set) var processingTrackID: UUID?
    @Published private(set) var processingTitle: String?
    @Published private(set) var stage = ""
    @Published private(set) var progress = 0.0
    @Published private(set) var requestedPlayback: KaraokePlayback?
    @Published var errorMessage: String?
    private let directory: URL
    private let defaults: UserDefaults
    private let runtimeOverride: KaraokeRuntime?
    private var track: Track?
    private var worker: Task<Void, Never>?
    private var process: KaraokeProcess?
    private var generation = UUID()
    private var playbackRequest: (trackID: UUID, apply: (KaraokePlayback, KaraokeAudio?) -> Void)?
    var isProcessing: Bool { processingTrackID != nil }

    init(directory: URL, model: KaraokeModel? = nil, defaults: UserDefaults = .standard, runtime: KaraokeRuntime? = nil) {
        self.directory = directory; self.defaults = defaults
        self.runtimeOverride = runtime
        if let model { self.models = [model]; self.model = model; return }
        let saved = defaults.data(forKey: "karaoke.models").flatMap { try? JSONDecoder().decode([KaraokeModel].self, from: $0) } ?? []
        var available = saved.compactMap { try? KaraokeModel(checkpoint: $0.checkpoint, configuration: $0.configuration).persisted(in: directory) }
        var legacy: KaraokeModel?
        if let checkpoint = defaults.string(forKey: "karaoke.checkpoint"), let config = defaults.string(forKey: "karaoke.configuration") {
            legacy = try? KaraokeModel(checkpoint: URL(fileURLWithPath: checkpoint), configuration: URL(fileURLWithPath: config))
        }
        for discovered in [legacy].compactMap({ $0 }) + KaraokeModel.discoverAll() {
            if let candidate = try? discovered.persisted(in: directory), !available.contains(where: { $0.id == candidate.id }) { available.append(candidate) }
        }
        for builtIn in (try? KaraokeModel.demucsModels(in: directory)) ?? [] {
            if !available.contains(where: { $0.id == builtIn.id }) { available.append(builtIn) }
        }
        self.models = available
        let selected = defaults.string(forKey: "karaoke.selectedModelID") ?? legacy?.id
        self.model = available.first(where: { $0.id == selected }) ?? available.first
    }

    func selectModel(id: String) {
        guard !isProcessing, let selected = models.first(where: { $0.id == id }), selected != model else { return }
        model = selected; clearPlaybackRequest(); errorMessage = nil; stage = ""; progress = 0
        refresh(for: track); persistModels()
    }

    func addModel(_ selected: KaraokeModel) {
        guard !isProcessing else { return }
        do {
            let saved = try selected.persisted(in: directory)
            if !models.contains(where: { $0.id == saved.id }) { models.append(saved) }
            selectModel(id: saved.id)
            persistModels()
        } catch { errorMessage = error.localizedDescription }
    }

    private func persistModels() {
        if let data = try? JSONEncoder().encode(models) { defaults.set(data, forKey: "karaoke.models") }
        defaults.set(model?.id, forKey: "karaoke.selectedModelID")
        defaults.set(model?.checkpoint.path, forKey: "karaoke.checkpoint")
        defaults.set(model?.configuration.path, forKey: "karaoke.configuration")
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

    /// Last click wins while all stems are prepared together. Original clears the
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
        if [.drums, .bass, .guitar, .piano, .other].contains(mode),
           model?.kind != .demucs || ([.guitar, .piano].contains(mode) && model?.checkpoint.pathExtension == "demucs" && model?.checkpoint.lastPathComponent != "htdemucs_6s.demucs") || (audio != nil && audio?.url(for: mode) == nil) {
            guard !isProcessing else {
                errorMessage = "Finish or cancel preparation before switching to the six-stem model."
                return
            }
            if let six = models.first(where: { $0.checkpoint.lastPathComponent == "htdemucs_6s.demucs" }) { selectModel(id: six.id) }
        }
        refresh(for: track)
        if let audio, mode == .mix || audio.url(for: mode) != nil {
            clearPlaybackRequest(); apply(mode, audio); return
        }
        if model == nil { chooseModel() }
        guard model != nil else { return }
        if let audio {
            guard mode == .mix || audio.url(for: mode) != nil else {
                errorMessage = "This model does not separate \(mode.title.lowercased()). Select Demucs 6 stems."
                return
            }
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
        panel.title = "Add karaoke model"
        panel.message = "Choose a Demucs safetensors model, UVR MDX ONNX model, or Mel-Band RoFormer checkpoint. Built-in Demucs models are available in the model menu."
        panel.allowedContentTypes = ["ckpt", "onnx", "safetensors"].map { UTType(filenameExtension: $0) ?? .data }
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let checkpoint = panel.url else { return }
        var configuration = KaraokeModel.configuration(for: checkpoint)
        if configuration == nil {
            let isMDX = checkpoint.pathExtension.lowercased() == "onnx"
            let configPanel = NSOpenPanel()
            configPanel.title = isMDX ? "Choose UVR MDX parameters" : "Choose model configuration"
            configPanel.message = isMDX ? "This model is not in the built-in catalog. Choose its matching UVR JSON parameter file."
                : "Choose the YAML configuration that came with this Mel-Band RoFormer checkpoint."
            configPanel.allowedContentTypes = (isMDX ? ["json"] : ["yaml", "yml"]).map { UTType(filenameExtension: $0) ?? .data }
            guard configPanel.runModal() == .OK, let selected = configPanel.url else { return }
            configuration = selected
        }
        do {
            guard let configuration else { return }
            let selected = try KaraokeModel(checkpoint: checkpoint, configuration: configuration)
            errorMessage = nil; addModel(selected)
        } catch { errorMessage = error.localizedDescription }
    }

    func prepare(_ track: Track) {
        guard !isProcessing else { return }
        errorMessage = nil
        refresh(for: track)
        if audio != nil { stage = "Ready — saved karaoke audio"; return }
        guard let model else { errorMessage = "Add and select a karaoke model first."; return }
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
                                                 modelSHA256: modelHash, directory: job, stemNames: event.stems)
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
                if self.track?.id == track.id, self.model == model { self.audio = result }
                self.stage = "Ready — karaoke audio saved"; self.progress = 1
                if self.track?.id == track.id, self.model == model, let request = self.playbackRequest,
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
        guard generation == token, isProcessing else { return }
        stage = event.stage; progress = event.progress.clamped(0, 1)
    }

    func exportInstrumental(title: String) { exportStem(.instrumental, title: title) }

    func exportAllStems(title: String) {
        guard let audio else { return }
        let panel = NSOpenPanel(); panel.title = "Export all stems"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let folder = destination.appendingPathComponent(title.replacingOccurrences(of: "/", with: "-") + " — Stems " + String(UUID().uuidString.prefix(8)))
        do {
            try audio.validate()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            do {
                for file in Set(Array(audio.stemFiles.values) + [audio.instrumental]) {
                    try FileManager.default.copyItem(at: file, to: folder.appendingPathComponent(file.lastPathComponent))
                }
            } catch { try? FileManager.default.removeItem(at: folder); throw error }
        } catch { errorMessage = error.localizedDescription }
    }

    func exportStem(_ stem: AudioStem, title: String) {
        guard let audio, let source = stem == .instrumental ? audio.instrumental : audio.stemFiles[stem] else { return }
        let panel = NSSavePanel()
        panel.title = "Export " + stem.title
        panel.allowedContentTypes = [.wav]
        panel.nameFieldStringValue = title.replacingOccurrences(of: "/", with: "-") + " — " + stem.title + ".wav"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try audio.validate()
            guard !Set(Array(audio.stemFiles.values) + [audio.instrumental]).contains(destination.standardizedFileURL),
                  destination.standardizedFileURL != track?.fileURL.standardizedFileURL else {
                throw KaraokeError.message("Choose a different filename so the original audio stays unchanged.")
            }
            let temporary = destination.deletingLastPathComponent().appendingPathComponent(".karaoke-export-" + UUID().uuidString + ".wav")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try FileManager.default.copyItem(at: source, to: temporary)
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
