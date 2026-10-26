import Foundation
import AVFoundation
import CryptoKit
import CoreFoundation
import Darwin

enum KaraokeModelKind: String, Codable {
    case melBandRoformer = "mel-band-roformer"
    case mdx, demucs
    var title: String { self == .demucs ? "Demucs · Apple GPU with CPU fallback · all model stems" : self == .mdx ? "UVR MDX · Core ML GPU preferred · CPU fallback" : "Mel-Band RoFormer · automatic device" }
}

struct KaraokeModel: Equatable, Codable, Identifiable {
    let checkpoint: URL
    let configuration: URL
    var kind: KaraokeModelKind { ["demucs", "safetensors"].contains(checkpoint.pathExtension.lowercased()) ? .demucs : checkpoint.pathExtension.lowercased() == "onnx" ? .mdx : .melBandRoformer }
    var id: String { checkpoint.standardizedFileURL.path + "\n" + configuration.standardizedFileURL.path }
    var title: String {
        if checkpoint.pathExtension == "demucs", let data = try? Data(contentsOf: checkpoint),
           let profile = try? JSONDecoder().decode(DemucsProfile.self, from: data) { return profile.title }
        return checkpoint.deletingPathExtension().lastPathComponent
    }
    struct DemucsProfile: Codable { let name: String; let title: String }
    static func demucsModels(in directory: URL) throws -> [KaraokeModel] {
        let profiles = [DemucsProfile(name: "htdemucs_6s", title: "Demucs · 6 stems (guitar + piano)"),
                        DemucsProfile(name: "htdemucs", title: "Demucs · 4 stems"),
                        DemucsProfile(name: "htdemucs_ft", title: "Demucs · 4 stems, fine-tuned"),
                        DemucsProfile(name: "hdemucs_mmi", title: "Demucs Hybrid · 4 stems"),
                        DemucsProfile(name: "mdx_extra", title: "Demucs MDX Extra · 4 stems")]
        let folder = directory.appendingPathComponent("ModelSettings")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try profiles.map { profile in
            let url = folder.appendingPathComponent(profile.name + ".demucs")
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            let data = try encoder.encode(profile)
            if (try? Data(contentsOf: url)) != data { try data.write(to: url, options: .atomic) }
            return try KaraokeModel(checkpoint: url, configuration: url)
        }
    }
    static var bundledMDXCatalog: URL? { Bundle.main.resourceURL?.appendingPathComponent("Karaoke/mdx-model-data.json") }

    init(checkpoint: URL, configuration: URL) throws {
        for file in [checkpoint, configuration] {
            let values = try FileManager.default.attributesOfItem(atPath: file.path)
            guard values[.type] as? FileAttributeType == .typeRegular,
                  ((values[.size] as? NSNumber)?.int64Value ?? 0) > 0,
                  FileManager.default.isReadableFile(atPath: file.path) else {
                throw KaraokeError.message("The model or its configuration is missing. Add its files again.")
            }
        }
        let ext = checkpoint.pathExtension.lowercased(), configExt = configuration.pathExtension.lowercased()
        guard (["demucs", "safetensors"].contains(ext) && checkpoint.standardizedFileURL == configuration.standardizedFileURL) || (ext == "ckpt" && ["yaml", "yml"].contains(configExt)) || (ext == "onnx" && configExt == "json") else {
            throw KaraokeError.message("Choose a Demucs safetensors file, a Mel-Band RoFormer checkpoint with YAML, or a UVR MDX ONNX model with matching JSON settings.")
        }
        self.checkpoint = checkpoint.resolvingSymlinksInPath(); self.configuration = configuration.resolvingSymlinksInPath()
        if kind == .mdx { try Self.validateMDX(checkpoint: checkpoint, configuration: configuration) }
    }

    static func validateMDX(checkpoint: URL, configuration: URL) throws {
        guard let data = try JSONSerialization.jsonObject(with: Data(contentsOf: configuration)) as? [String: Any] else {
            throw KaraokeError.message("The MDX settings must contain a JSON object.")
        }
        let parameters: [String: Any]?
        if data["mdx_dim_f_set"] != nil { parameters = data }
        else { parameters = data[try uvrHash(checkpoint)] as? [String: Any] }
        guard let parameters, ["Vocals", "Instrumental"].contains(parameters["primary_stem"] as? String ?? ""),
              ["mdx_dim_f_set", "mdx_dim_t_set", "mdx_n_fft_scale_set", "compensate"].allSatisfy({ parameters[$0] is NSNumber }) else {
            throw KaraokeError.message("This ONNX model needs its matching UVR vocal/instrumental JSON settings. Choose a parameter file instead of guessing its format.")
        }
        func integer(_ key: String) -> Int? {
            guard let value = parameters[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue.isFinite, value.doubleValue.rounded() == value.doubleValue,
                  (0...32768).contains(value.doubleValue) else { return nil }
            return value.intValue
        }
        guard let fft = integer("mdx_n_fft_scale_set"), let frequency = integer("mdx_dim_f_set"), let exponent = integer("mdx_dim_t_set"),
              (2048...32768).contains(fft), fft % 2 == 0, (1...(fft / 2 + 1)).contains(frequency), (4...10).contains(exponent),
              1024 * ((1 << exponent) - 1) > fft,
              let gain = parameters["compensate"] as? NSNumber, CFGetTypeID(gain) != CFBooleanGetTypeID(),
              gain.doubleValue.isFinite, gain.doubleValue > 0, gain.doubleValue <= 4 else {
            throw KaraokeError.message("The UVR MDX parameter file contains unsupported dimensions or compensation.")
        }
    }

    static func uvrHash(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        try handle.seek(toOffset: size > 10_240_000 ? size - 10_240_000 : 0)
        return Insecure.MD5.hash(data: try handle.readToEnd() ?? Data()).map { String(format: "%02x", $0) }.joined()
    }

    /// Keep imported MDX settings outside the app bundle so moving/updating the
    /// app cannot invalidate saved model entries. Weights stay at their source.
    func persisted(in directory: URL) throws -> KaraokeModel {
        guard kind == .mdx else { return self }
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: configuration)) as? [String: Any] else {
            throw KaraokeError.message("The MDX settings must contain a JSON object.")
        }
        let parameters = object["mdx_dim_f_set"] == nil ? object[try Self.uvrHash(checkpoint)] as? [String: Any] : object
        guard let settings = parameters else {
            throw KaraokeError.message("The MDX settings no longer contain this model. Add its matching JSON settings again.")
        }
        let data = try JSONSerialization.data(withJSONObject: settings, options: .sortedKeys)
        let key = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let folder = directory.appendingPathComponent("ModelSettings", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(key + ".json")
        if (try? Data(contentsOf: file)) != data { try data.write(to: file, options: .atomic) }
        return try KaraokeModel(checkpoint: checkpoint, configuration: file)
    }

    static func configuration(for checkpoint: URL, mdxCatalog: URL? = bundledMDXCatalog) -> URL? {
        let base = checkpoint.deletingPathExtension(), folder = checkpoint.deletingLastPathComponent()
        if ["demucs", "safetensors"].contains(checkpoint.pathExtension.lowercased()) { return checkpoint }
        if checkpoint.pathExtension.lowercased() == "onnx" {
            for candidate in [base.appendingPathExtension("json"), mdxCatalog].compactMap({ $0 }) {
                if (try? KaraokeModel(checkpoint: checkpoint, configuration: candidate)) != nil { return candidate }
            }
        } else {
            var candidates = [base.appendingPathExtension("yaml"), base.appendingPathExtension("yml"),
                              folder.appendingPathComponent("config_" + base.lastPathComponent + ".yaml")]
            if base.lastPathComponent.lowercased() == "becruily_deux" { candidates.insert(folder.appendingPathComponent("config_deux_becruily.yaml"), at: 0) }
            for candidate in candidates where FileManager.default.isReadableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    static func discoverAll(in downloads: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads"),
                            mdxCatalog: URL? = bundledMDXCatalog) -> [KaraokeModel] {
        var models: [KaraokeModel] = []
        for folder in [downloads.appendingPathComponent("Otras"), downloads] {
            let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
            for file in files.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
                where ["ckpt", "onnx"].contains(file.pathExtension.lowercased()) {
                if let config = configuration(for: file, mdxCatalog: mdxCatalog),
                   let model = try? KaraokeModel(checkpoint: file, configuration: config), !models.contains(where: { $0.id == model.id }) { models.append(model) }
            }
        }
        return models
    }

    static func discover(in downloads: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")) -> KaraokeModel? {
        discoverAll(in: downloads).first
    }

    func cacheKey(trackID: UUID, source: URL) throws -> String {
        let config = checkpoint.pathExtension == "safetensors" ? Data() : try Data(contentsOf: configuration)
        // Preserve existing Becruily caches; MDX output uses its own processing version.
        let version = kind == .demucs ? "demucs-4.1-six-stems-v1" : kind == .mdx ? "uvr-mdx-overlap-v1" : "becruily-deux-overlap-v1"
        let parts = [version, trackID.uuidString, try Self.identity(source),
                     try Self.identity(checkpoint), configuration.path,
                     SHA256.hash(data: config).map { String(format: "%02x", $0) }.joined()]
        return SHA256.hash(data: Data(parts.joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    private static func identity(_ url: URL) throws -> String {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular else {
            throw KaraokeError.message("The source or model is not a regular file.")
        }
        return "\(url.standardizedFileURL.path)|\(attrs[.size] ?? 0)|\((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)|\(attrs[.systemFileNumber] ?? 0)"
    }
}

enum KaraokeError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let text): return text } }
}

struct KaraokeAudio: Codable, Equatable {
    let key: String
    let trackID: UUID
    let frames: Int64
    let sampleRate: Double
    let modelSHA256: String
    var directory: URL
    var stemNames: [String]? = nil
    var instrumental: URL { directory.appendingPathComponent("instrumental.wav") }
    var vocals: URL { directory.appendingPathComponent("vocals.wav") }

    var availableStems: [AudioStem] {
        (stemNames ?? ["vocals", "instrumental"]).compactMap(AudioStem.init(rawValue:))
    }
    var stemFiles: [AudioStem: URL] {
        Dictionary(uniqueKeysWithValues: availableStems.map { ($0, directory.appendingPathComponent($0.rawValue + ".wav")) })
    }
    func url(for mode: KaraokePlayback) -> URL? {
        if mode == .mix { return instrumental }
        guard let stem = mode.stem else { return nil }
        if stem == .instrumental { return instrumental }
        return stemFiles[stem]
    }

    func validate() throws {
        guard sampleRate == 44_100, frames > 0, Set(stemNames ?? []).count == (stemNames ?? []).count, (stemNames ?? []).allSatisfy({ AudioStem(rawValue: $0) != nil }) else { throw KaraokeError.message("The saved karaoke audio is incomplete. Prepare it again.") }
        for file in Set([instrumental, vocals] + Array(stemFiles.values)) {
            let reader = try AVAudioFile(forReading: file)
            guard reader.length == frames, reader.fileFormat.sampleRate == sampleRate,
                  reader.fileFormat.channelCount == 2 else {
                throw KaraokeError.message("The saved karaoke audio is incomplete. Prepare it again.")
            }
        }
    }
}

struct KaraokeRuntime {
    let python: URL
    let packages: URL
    let helper: URL

    static func bundled() throws -> KaraokeRuntime {
        #if arch(x86_64)
        var arm64: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.optional.arm64", &arm64, &size, nil, 0) == 0, arm64 == 1 else {
            throw KaraokeError.message("Karaoke processing in this build requires an Apple silicon Mac.")
        }
        #endif
        guard let resources = Bundle.main.resourceURL else { throw KaraokeError.message("The karaoke processor is missing from this app.") }
        let runtime = resources.appendingPathComponent("KaraokeRuntime", isDirectory: true)
        let result = KaraokeRuntime(python: runtime.appendingPathComponent("python/bin/python3"),
                                    packages: runtime.appendingPathComponent("site-packages"),
                                    helper: resources.appendingPathComponent("Karaoke/separate.py"))
        guard FileManager.default.isExecutableFile(atPath: result.python.path),
              FileManager.default.fileExists(atPath: result.helper.path) else {
            throw KaraokeError.message("This build does not include karaoke processing. Open the Mac build with the karaoke processor included.")
        }
        // The bundled inference runtime for this build targets Apple silicon.
        // Running an Intel slice under Rosetta still launches the arm64 helper.
        return result
    }
}

struct KaraokeProgress: Decodable, Sendable {
    let stage: String
    let progress: Double
    var error: String?
    var frames: Int64?
    var sample_rate: Double?
    var model_sha256: String?
    var stems: [String]?
}

/// A cancellable worker process; pipe reads and waiting happen off the main thread.
final class KaraokeProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var child: Process?
    private var cancelled = false

    func checkCancellation() throws {
        lock.lock(); let stopped = cancelled; lock.unlock()
        if stopped { throw CancellationError() }
    }

    func cancel() {
        lock.lock(); cancelled = true
        if let child, child.isRunning { child.terminate() }
        lock.unlock()
    }

    func run(runtime: KaraokeRuntime, model: KaraokeModel, input: URL, output: URL,
             progress: @escaping @Sendable (KaraokeProgress) -> Void) throws -> KaraokeProgress {
        let process = Process(), pipe = Pipe()
        process.executableURL = runtime.python
        process.arguments = [runtime.helper.path, "--backend", model.kind.rawValue, "--checkpoint", model.checkpoint.path,
                             "--config", model.configuration.path, "--input", input.path, "--output", output.path]
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONPATH"] = [runtime.packages.path, runtime.helper.deletingLastPathComponent().path].joined(separator: ":")
        environment["PYTHONNOUSERSITE"] = "1"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"
        environment["NUMBA_CACHE_DIR"] = output.appendingPathComponent(".numba-cache").path
        if model.kind == .mdx {
            // Core ML needs a writable compilation workspace, separate from the
            // persistent converted-model cache beside this temporary job folder.
            environment["TMPDIR"] = output.path + "/"
        }
        environment.removeValue(forKey: "PYTHONHOME")
        process.environment = environment
        process.standardOutput = pipe
        let log = output.appendingPathComponent("processor.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let errors = try FileHandle(forWritingTo: log)
        defer { try? errors.close(); try? pipe.fileHandleForReading.close() }
        process.standardError = errors
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        child = process
        do { try process.run() } catch { lock.unlock(); throw error }
        lock.unlock()
        var pending = Data(), result: KaraokeProgress?
        while true {
            let data = pipe.fileHandleForReading.availableData
            if data.isEmpty { break }
            pending.append(data)
            guard pending.count < 1_048_576 else { process.terminate(); process.waitUntilExit(); throw KaraokeError.message("The processor returned an unreadable response.") }
            while let end = pending.firstIndex(of: 10) {
                let line = pending.prefix(upTo: end)
                pending.removeSubrange(...end)
                if let event = try? JSONDecoder().decode(KaraokeProgress.self, from: line) {
                    result = event; progress(event)
                }
            }
        }
        process.waitUntilExit()
        lock.lock(); let wasCancelled = cancelled; child = nil; lock.unlock()
        if wasCancelled { throw CancellationError() }
        guard process.terminationStatus == 0, let result, result.stage == "Ready" else {
            throw KaraokeError.message(result?.error ?? "Karaoke processing could not finish. Check that the model matches its configuration and try again.")
        }
        return result
    }
}

enum KaraokePreparation {
    static func decode(source: URL, to destination: URL, checkCancellation: @Sendable () throws -> Void = {}) async throws -> Int64 {
        let decoder = try PCMDecoder(url: source, sampleRate: 44_100)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let file = try AVAudioFile(forWriting: destination, settings: format.settings)
        var frames: Int64 = 0
        while let chunk = try await decoder.read() {
            try Task.checkCancellation()
            try checkCancellation()
            try file.write(from: chunk.buffer)
            frames += Int64(chunk.buffer.frameLength)
        }
        guard frames > 0 else { throw KaraokeError.message("This track contains no readable audio.") }
        return frames
    }
}
