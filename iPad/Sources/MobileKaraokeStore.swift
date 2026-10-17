import AVFoundation
import Combine
import CryptoKit
import Foundation

@MainActor final class MobileKaraokeStore: ObservableObject {
  @Published private(set) var models: [MobileKaraokeModel] = []
  @Published private(set) var selectedID: UUID?
  @Published private(set) var audio: KaraokeAudio?
  @Published private(set) var processing = false
  @Published private(set) var processingTrackID: UUID?
  @Published private(set) var processingTitle: String?
  @Published private(set) var importingModel = false
  @Published private(set) var cancelling = false
  @Published private(set) var progress = 0.0
  @Published private(set) var stage = ""
  @Published var error: String?
  private var worker: Task<Void, Never>?
  private var cancellation: NativeKaraokeCancellation?
  private var currentTrack: Track?
  private var revision = UUID()
  private var removedTracks = Set<UUID>()
  private var pending: (UUID, KaraokePlayback, (KaraokePlayback, KaraokeAudio?) -> Void)?
  let root: URL
  var modelRoot: URL { root.appendingPathComponent("Models", isDirectory: true) }
  var selected: MobileKaraokeModel? { models.first { $0.id == selectedID } }
  private var stateURL: URL { root.appendingPathComponent("Models.json") }
  private struct Saved: Codable {
    let models: [MobileKaraokeModel]
    let selected: UUID?
  }
  init(root: URL) {
    self.root = root
    try? FileManager.default.createDirectory(at: modelRoot, withIntermediateDirectories: true)
    let leftovers =
      (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))
      ?? []
    for item in leftovers
    where [".job-", ".saved-", ".import-stems-"].contains(where: {
      item.lastPathComponent.hasPrefix($0)
    }) { try? FileManager.default.removeItem(at: item) }
    if let data = try? Data(contentsOf: stateURL),
      let saved = try? JSONDecoder().decode(Saved.self, from: data)
    {
      models = saved.models.filter {
        FileManager.default.fileExists(
          atPath: $0.url(in: root.appendingPathComponent("Models")).path)
      }
      selectedID = saved.selected.flatMap { selected in
        models.first(where: { $0.id == selected })?.id
      }
    }
  }
  private func save() {
    do {
      try JSONEncoder().encode(Saved(models: models, selected: selectedID)).write(
        to: stateURL, options: .atomic)
    } catch { self.error = error.localizedDescription }
  }
  func select(_ id: UUID?, player: PlayerEngine) {
    guard !processing, !importingModel, id != selectedID,
      id == nil || models.contains(where: { $0.id == id })
    else {
      return
    }
    selectedID = id
    pending = nil
    error = nil
    player.setKaraokePlayback(.original)
    refresh(player.currentTrack)
    save()
  }
  func importModel(_ source: URL, settings: URL? = nil) async throws {
    guard !processing, !importingModel else { return }
    importingModel = true
    defer { importingModel = false }
    let accessed = source.startAccessingSecurityScopedResource()
    defer { if accessed { source.stopAccessingSecurityScopedResource() } }
    let scope = settings?.startAccessingSecurityScopedResource() ?? false
    defer { if scope { settings?.stopAccessingSecurityScopedResource() } }
    let id = UUID()
    let folder = modelRoot.appendingPathComponent(id.uuidString, isDirectory: true)
    let destination = folder.appendingPathComponent(source.lastPathComponent)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    do {
      try await Task.detached(priority: .userInitiated) {
        try LibraryStore.coordinated(source) {
          try FileManager.default.copyItem(at: $0, to: destination)
        }
      }.value
      let ext = source.pathExtension.lowercased()
      let backend: MobileKaraokeModel.Backend = ext == "onnx" ? .mdx : .coreML
      guard ["onnx", "mlmodel", "mlmodelc", "mlpackage"].contains(ext) else {
        throw NativeKaraokeError.message(
          "Add an ONNX MDX or converted Core ML model. The iPad cannot execute raw Python/PyTorch checkpoint files."
        )
      }
      let catalog = Bundle.main.url(forResource: "mdx-model-data", withExtension: "json")
      let parameters: MDXParameters?
      if backend == .mdx {
        guard let config = settings ?? catalog else {
          throw NativeKaraokeError.message("Import this model’s matching UVR JSON settings.")
        }
        parameters = try await Task.detached(priority: .userInitiated) {
          try MobileKaraokeModel.parameters(file: config, model: destination)
        }.value
      } else {
        parameters = nil
      }
      let digest = try await Task.detached(priority: .userInitiated) {
        try MobileKaraokeModel.digest(destination)
      }.value
      if let existing = models.first(where: { $0.digest == digest && $0.parameters == parameters })
      {
        selectedID = existing.id
        try? FileManager.default.removeItem(at: folder)
      } else {
        let model = MobileKaraokeModel(
          id: id, name: source.deletingPathExtension().lastPathComponent,
          filename: source.lastPathComponent, digest: digest, parameters: parameters,
          backend: backend)
        models.append(model)
        selectedID = id
      }
      error = nil
      pending = nil
      refresh(currentTrack)
      save()
    } catch {
      try? FileManager.default.removeItem(at: folder)
      throw error
    }
  }
  private func key(_ track: Track, model: MobileKaraokeModel) -> String {
    let parameters = model.parameterData
    let value =
      track.id.uuidString + "|" + track.fingerprint + "|" + model.digest + "|"
      + parameters.base64EncodedString() + "|native-ipad-v1"
    return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }
  func refresh(_ track: Track?) {
    if currentTrack?.id != track?.id { pending = nil }
    currentTrack = track
    audio = nil
    guard let track else { return }
    let imported = root.appendingPathComponent("ImportedStems/" + track.id.uuidString)
    let folders =
      selected.map { [root.appendingPathComponent(key(track, model: $0))] } ?? [imported]
    for folder in folders {
      if let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
        var saved = try? JSONDecoder().decode(KaraokeAudio.self, from: data),
        saved.trackID == track.id
      {
        saved.directory = folder
        if (try? saved.validate()) != nil {
          audio = saved
          return
        }
      }
    }
  }
  func request(
    _ mode: KaraokePlayback, track: Track, apply: @escaping (KaraokePlayback, KaraokeAudio?) -> Void
  ) {
    error = nil
    if mode == .original {
      pending = nil
      apply(mode, nil)
      return
    }
    guard !importingModel else {
      error = "Wait for the import to finish."
      return
    }
    guard !processing || processingTrackID == track.id else {
      error = "Finish or cancel the current preparation first."
      return
    }
    refresh(track)
    if let audio {
      pending = nil
      apply(mode, audio)
      return
    }
    guard selected != nil else {
      error =
        "Add a karaoke model in the Karaoke tab first, or import prepared stems from the Mac app."
      return
    }
    pending = (track.id, mode, apply)
    if !processing { prepare(track) }
  }
  func prepare(_ track: Track) {
    guard !processing, !importingModel, let model = selected else { return }
    refresh(track)
    if audio != nil {
      if let pending {
        self.pending = nil
        pending.2(pending.1, audio)
      }
      return
    }
    processing = true
    processingTrackID = track.id
    processingTitle = track.title
    cancelling = false
    progress = 0
    stage = "Preparing source audio"
    error = nil
    let token = UUID()
    revision = token
    let cancel = NativeKaraokeCancellation()
    cancellation = cancel
    let target = MobileKaraokeProgress(store: self, token: token)
    let root = self.root
    let models = modelRoot
    let key = key(track, model: model)
    worker = Task { [weak self] in
      do {
        let result = try await Task.detached(priority: .userInitiated) {
          let job = root.appendingPathComponent(".job-" + token.uuidString, isDirectory: true)
          try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
          defer { try? FileManager.default.removeItem(at: job) }
          let input = job.appendingPathComponent("source.wav")
          try await Self.decodeAudio(source: track.fileURL, to: input, cancel: cancel)
          return try Self.finishDecoded(
            input: input, job: job, root: root, models: models, model: model, track: track,
            key: key, cancel: cancel, notify: { stage, value in target.send(stage, value) })
        }.value
        guard let self, self.revision == token else { return }
        try cancel.check()
        if self.currentTrack?.id == track.id, self.selectedID == model.id { self.audio = result }
        self.processing = false
        self.processingTrackID = nil
        self.processingTitle = nil
        self.cancelling = false
        self.progress = 1
        self.stage = "Prepared audio saved"
        if let pending = self.pending, pending.0 == track.id, self.currentTrack?.id == track.id,
          self.selectedID == model.id
        {
          self.pending = nil
          pending.2(pending.1, result)
        }
      } catch {
        guard let self, self.revision == token else { return }
        self.processing = false
        self.processingTrackID = nil
        self.processingTitle = nil
        self.cancelling = false
        self.pending = nil
        if error is CancellationError {
          self.stage = "Preparation cancelled"
        } else {
          self.error = error.localizedDescription
          self.stage = "Preparation stopped"
        }
      }
    }
  }
  nonisolated private static func decodeAudio(
    source: URL, to input: URL, cancel: NativeKaraokeCancellation
  ) async throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
    let decoder = try PCMDecoder(url: source, sampleRate: 44100)
    let file = try AVAudioFile(forWriting: input, settings: format.settings)
    while let chunk = try await decoder.read() {
      try cancel.check()
      try file.write(from: chunk.buffer)
    }
  }
  nonisolated private static func finishDecoded(
    input: URL, job: URL, root: URL, models: URL, model: MobileKaraokeModel, track: Track,
    key: String, cancel: NativeKaraokeCancellation,
    notify: @escaping @Sendable (String, Double) -> Void
  ) throws -> KaraokeAudio {
    let frames = try NativeKaraokeEngine.prepare(
      input: input, output: job, model: model, models: models,
      cache: root.appendingPathComponent("ModelCache"), cancellation: cancel, notify: notify)
    try cancel.check()
    let folder = root.appendingPathComponent(key, isDirectory: true)
    var audio = KaraokeAudio(
      key: key, trackID: track.id, frames: frames, sampleRate: 44100, modelSHA256: model.digest,
      directory: job)
    try audio.validate()
    // Never move the potentially huge source/scratch files into the saved stems.
    let staging = root.appendingPathComponent(".saved-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: staging) }
    for name in ["vocals.wav", "instrumental.wav"] {
      try FileManager.default.moveItem(
        at: job.appendingPathComponent(name), to: staging.appendingPathComponent(name))
    }
    audio.directory = folder
    try JSONEncoder().encode(audio).write(
      to: staging.appendingPathComponent("manifest.json"), options: .atomic)
    try cancel.commit {
      if FileManager.default.fileExists(atPath: folder.path) {
        try FileManager.default.removeItem(at: folder)
      }
      try FileManager.default.moveItem(at: staging, to: folder)
    }
    return audio
  }
  fileprivate func receive(_ stage: String, value: Double, token: UUID) {
    guard revision == token, processing else { return }
    if !cancelling { self.stage = stage }
    progress = value
  }
  func cancel() {
    guard processing else { return }
    pending = nil
    cancelling = true
    stage = "Cancelling preparation…"
    cancellation?.cancel()
    worker?.cancel()
  }
  func purge(_ ids: Set<UUID>) {
    removedTracks.formUnion(ids)
    if let processingTrackID, ids.contains(processingTrackID) { cancel() }
    if let currentTrack, ids.contains(currentTrack.id) {
      self.currentTrack = nil
      audio = nil
      pending = nil
    }
    for folder
      in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))
      ?? []
    {
      if let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
        let manifest = try? JSONDecoder().decode(KaraokeAudio.self, from: data),
        ids.contains(manifest.trackID)
      {
        try? FileManager.default.removeItem(at: folder)
      }
    }
    for id in ids {
      try? FileManager.default.removeItem(
        at: root.appendingPathComponent("ImportedStems/" + id.uuidString))
    }
  }
  func removeSelected(player: PlayerEngine) {
    guard !processing, !importingModel, let selected else { return }
    player.setKaraokePlayback(.original)
    models.removeAll { $0.id == selected.id }
    selectedID = models.first?.id
    try? FileManager.default.removeItem(
      at: modelRoot.appendingPathComponent(selected.id.uuidString))
    if !models.contains(where: { $0.digest == selected.digest }) {
      let candidates =
        (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil))
        ?? []
      for folder in candidates {
        if let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
          let manifest = try? JSONDecoder().decode(KaraokeAudio.self, from: data),
          manifest.modelSHA256 == selected.digest
        {
          try? FileManager.default.removeItem(at: folder)
        }
      }
      let cache = root.appendingPathComponent("ModelCache")
      for folder
        in (try? FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil))
        ?? [] where folder.lastPathComponent.hasPrefix(selected.digest)
      { try? FileManager.default.removeItem(at: folder) }
    }
    pending = nil
    refresh(currentTrack)
    save()
  }
  func importStems(vocals: URL, instrumental: URL, track: Track) async throws {
    guard !processing, !importingModel else { return }
    importingModel = true
    defer { importingModel = false }
    let scoped = [vocals, instrumental].filter { $0.startAccessingSecurityScopedResource() }
    defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
    let root = self.root
    try await Task.detached(priority: .userInitiated) {
      let folder = root.appendingPathComponent(
        "ImportedStems/" + track.id.uuidString, isDirectory: true)
      let job = root.appendingPathComponent(".import-stems-" + UUID().uuidString)
      try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: job) }
      for (source, name) in [(vocals, "vocals.wav"), (instrumental, "instrumental.wav")] {
        try LocalAudioImport.coordinated(source) {
          try FileManager.default.copyItem(at: $0, to: job.appendingPathComponent(name))
        }
        try FileManager.default.setAttributes(
          [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
          ofItemAtPath: job.appendingPathComponent(name).path)
      }
      let file = try AVAudioFile(forReading: job.appendingPathComponent("vocals.wav"))
      var audio = KaraokeAudio(
        key: track.id.uuidString, trackID: track.id, frames: file.length, sampleRate: 44100,
        modelSHA256: "imported-stems", directory: job)
      try audio.validate()
      guard abs(Double(file.length) / 44100 - track.duration) < 0.25 else {
        throw NativeKaraokeError.message(
          "The prepared stems must match the full length of this track.")
      }
      try FileManager.default.createDirectory(
        at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
      audio.directory = folder
      try JSONEncoder().encode(audio).write(
        to: job.appendingPathComponent("manifest.json"), options: .atomic)
      if FileManager.default.fileExists(atPath: folder.path) {
        try FileManager.default.removeItem(at: folder)
      }
      try FileManager.default.moveItem(at: job, to: folder)
    }.value
    if removedTracks.contains(track.id) {
      try? FileManager.default.removeItem(
        at: root.appendingPathComponent("ImportedStems/" + track.id.uuidString))
      throw NativeKaraokeError.message("The track was removed before the stem import finished.")
    }
    if currentTrack?.id == track.id {
      selectedID = nil
      save()
      refresh(currentTrack)
    }
  }

}

@MainActor private final class MobileKaraokeProgress: Sendable {
  weak var store: MobileKaraokeStore?
  let token: UUID
  init(store: MobileKaraokeStore, token: UUID) {
    self.store = store
    self.token = token
  }
  nonisolated func send(_ stage: String, _ value: Double) {
    Task { @MainActor [weak self] in
      guard let self else { return }
      self.store?.receive(stage, value: value, token: self.token)
    }
  }
}
