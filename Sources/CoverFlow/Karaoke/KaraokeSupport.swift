import Foundation
import AVFoundation
import CryptoKit
import Darwin

enum KaraokePlayback: String, CaseIterable, Identifiable {
    case original, instrumental, vocals
    var id: String { rawValue }
    var title: String {
        switch self { case .original: return "Original"; case .instrumental: return "Karaoke"; case .vocals: return "Vocals" }
    }
}

struct KaraokeModel: Equatable {
    let checkpoint: URL
    let configuration: URL

    init(checkpoint: URL, configuration: URL) throws {
        for file in [checkpoint, configuration] {
            let values = try FileManager.default.attributesOfItem(atPath: file.path)
            guard values[.type] as? FileAttributeType == .typeRegular,
                  ((values[.size] as? NSNumber)?.int64Value ?? 0) > 0,
                  FileManager.default.isReadableFile(atPath: file.path) else {
                throw KaraokeError.message("The model or its configuration is missing. Choose the Becruily Deux files again.")
            }
        }
        guard checkpoint.pathExtension.lowercased() == "ckpt",
              ["yaml", "yml"].contains(configuration.pathExtension.lowercased()) else {
            throw KaraokeError.message("Choose the Becruily Deux checkpoint and its matching YAML configuration.")
        }
        self.checkpoint = checkpoint; self.configuration = configuration
    }

    static func discover(in downloads: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")) -> KaraokeModel? {
        for directory in [downloads.appendingPathComponent("Otras"), downloads] {
            if let found = try? KaraokeModel(checkpoint: directory.appendingPathComponent("becruily_deux.ckpt"),
                                             configuration: directory.appendingPathComponent("config_deux_becruily.yaml")) {
                return found
            }
        }
        return nil
    }

    func cacheKey(trackID: UUID, source: URL) throws -> String {
        let config = try Data(contentsOf: configuration)
        let parts = ["becruily-deux-overlap-v1", trackID.uuidString, try Self.identity(source),
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
    var instrumental: URL { directory.appendingPathComponent("instrumental.wav") }
    var vocals: URL { directory.appendingPathComponent("vocals.wav") }

    func url(for mode: KaraokePlayback) -> URL? {
        switch mode { case .original: return nil; case .instrumental: return instrumental; case .vocals: return vocals }
    }

    func validate() throws {
        guard sampleRate == 44_100, frames > 0 else { throw KaraokeError.message("The saved karaoke audio is incomplete. Prepare it again.") }
        for file in [instrumental, vocals] {
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
        process.arguments = [runtime.helper.path, "--checkpoint", model.checkpoint.path,
                             "--config", model.configuration.path, "--input", input.path, "--output", output.path]
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONPATH"] = [runtime.packages.path, runtime.helper.deletingLastPathComponent().path].joined(separator: ":")
        environment["PYTHONNOUSERSITE"] = "1"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTORCH_ENABLE_MPS_FALLBACK"] = "1"
        environment["NUMBA_CACHE_DIR"] = output.appendingPathComponent(".numba-cache").path
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
