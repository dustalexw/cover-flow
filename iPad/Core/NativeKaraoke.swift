import AVFoundation
import CoreML
import CryptoKit
import Darwin
import Foundation

#if canImport(NativeMDX)
  import NativeMDX
#endif

enum KaraokePlayback: String, CaseIterable, Identifiable {
  case original, instrumental, vocals
  var id: String { rawValue }
  var title: String {
    self == .original ? "Original" : self == .instrumental ? "Karaoke" : "Vocals Only"
  }
}
struct KaraokeAudio: Codable, Equatable, Sendable {
  let key: String
  let trackID: UUID
  let frames: Int64
  let sampleRate: Double
  let modelSHA256: String
  var directory: URL
  var instrumental: URL { directory.appendingPathComponent("instrumental.wav") }
  var vocals: URL { directory.appendingPathComponent("vocals.wav") }
  func url(for mode: KaraokePlayback) -> URL? {
    mode == .original ? nil : mode == .instrumental ? instrumental : vocals
  }
  func validate() throws {
    guard frames > 0, sampleRate == 44100 else {
      throw NativeKaraokeError.message("Incomplete prepared audio.")
    }
    for url in [instrumental, vocals] {
      let file = try AVAudioFile(forReading: url)
      guard file.length == frames, file.fileFormat.sampleRate == 44100,
        file.fileFormat.channelCount == 2
      else {
        throw NativeKaraokeError.message(
          "The two stems must be stereo 44.1 kHz audio of the same length.")
      }
    }
  }
}
struct MobileKaraokeModel: Codable, Identifiable, Equatable, Sendable {
  enum Backend: String, Codable { case mdx, coreML }
  var id: UUID
  var name: String
  var filename: String
  var digest: String
  var parameters: MDXParameters?
  var backend: Backend
  var parameterData: Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return (try? encoder.encode(parameters)) ?? Data()
  }
  func url(in root: URL) -> URL {
    root.appendingPathComponent(id.uuidString).appendingPathComponent(filename)
  }
  static func digest(_ url: URL) throws -> String {
    var hash = SHA256()
    let directory = (try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true
    let files: [URL]
    if directory {
      files =
        ((FileManager.default.enumerator(
          at: url, includingPropertiesForKeys: [.isRegularFileKey], options: .skipsHiddenFiles)?
        .allObjects as? [URL]) ?? []).filter {
          (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }.sorted { $0.path < $1.path }
    } else {
      files = [url]
    }
    for item in files {
      if directory {
        hash.update(data: Data(item.path.replacingOccurrences(of: url.path, with: "").utf8))
      }
      let file = try FileHandle(forReadingFrom: item)
      defer { try? file.close() }
      while let data = try file.read(upToCount: 1_048_576), !data.isEmpty {
        hash.update(data: data)
      }
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
  static func uvrHash(_ url: URL) throws -> String {
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    let size = try file.seekToEnd()
    try file.seek(toOffset: size > 10_240_000 ? size - 10_240_000 : 0)
    return Insecure.MD5.hash(data: try file.readToEnd() ?? Data()).map {
      String(format: "%02x", $0)
    }.joined()
  }
  static func parameters(file: URL, model: URL) throws -> MDXParameters {
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: 2 * 1024 * 1024 + 1) ?? Data()
    guard data.count <= 2 * 1024 * 1024 else {
      throw NativeKaraokeError.message("Choose UVR JSON settings smaller than 2 MB.")
    }
    let decoder = JSONDecoder()
    if let flat = try? decoder.decode(MDXParameters.self, from: data) {
      try flat.validate()
      return flat
    }
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    guard let selected = object?[try uvrHash(model)] else {
      throw NativeKaraokeError.needsMDXSettings
    }
    let settings = try decoder.decode(
      MDXParameters.self, from: JSONSerialization.data(withJSONObject: selected))
    try settings.validate()
    return settings
  }
}

/// Cancellation can stop an active ONNX run; Core ML compilation finishes its
/// current system call before the task observes cancellation and cleans up.
final class NativeKaraokeCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var runtime: CFMDXRuntime?
  private var cancelled = false
  func install(_ value: CFMDXRuntime) throws {
    lock.lock()
    defer { lock.unlock() }
    if cancelled { throw CancellationError() }
    runtime = value
  }
  func cancel() {
    lock.lock()
    cancelled = true
    runtime?.cancel()
    lock.unlock()
  }
  func commit<T>(_ operation: () throws -> T) throws -> T {
    lock.lock()
    defer { lock.unlock() }
    if cancelled { throw CancellationError() }
    return try operation()
  }
  func check() throws {
    lock.lock()
    let stopped = cancelled
    lock.unlock()
    if stopped { throw CancellationError() }
  }
}
private final class ScratchFloats {
  let pointer: UnsafeMutablePointer<Float>
  let count: Int
  private let descriptor: Int32
  init(url: URL, count: Int) throws {
    self.count = count
    descriptor = open(url.path, O_RDWR | O_CREAT | O_TRUNC, 0o600)
    guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
    guard ftruncate(descriptor, off_t(count * 4)) == 0 else {
      close(descriptor)
      throw CocoaError(.fileWriteOutOfSpace)
    }
    let mapping = mmap(nil, count * 4, PROT_READ | PROT_WRITE, MAP_SHARED, descriptor, 0)
    guard mapping != MAP_FAILED, let mapping else {
      close(descriptor)
      throw CocoaError(.fileWriteOutOfSpace)
    }
    pointer = mapping.assumingMemoryBound(to: Float.self)
  }
  deinit {
    munmap(pointer, count * 4)
    close(descriptor)
  }
  subscript(_ index: Int) -> Float {
    get { pointer[index] }
    set { pointer[index] = newValue }
  }
}

private final class WaveformModel {
  let model: MLModel
  let input: String
  let output: String
  let chunk: Int
  init(url: URL, compiledCache: URL) throws {
    let loaded: URL
    if url.pathExtension == "mlmodelc" {
      loaded = url
    } else if FileManager.default.fileExists(atPath: compiledCache.path) {
      loaded = compiledCache
    } else {
      let temporary = try MLModel.compileModel(at: url)
      try FileManager.default.moveItem(at: temporary, to: compiledCache)
      loaded = compiledCache
    }
    let options = MLModelConfiguration()
    options.computeUnits = .cpuAndGPU
    model = try MLModel(contentsOf: loaded, configuration: options)
    let description = model.modelDescription
    guard description.inputDescriptionsByName.count == 1,
      description.outputDescriptionsByName.count == 1,
      let input = description.inputDescriptionsByName.first,
      let inputShape = input.value.multiArrayConstraint?.shape.map(\.intValue),
      input.value.multiArrayConstraint?.dataType == .float32,
      inputShape.count == 3, inputShape[0] == 1, inputShape[1] == 2,
      (8192...1_048_576).contains(inputShape[2]),
      let output = description.outputDescriptionsByName.first,
      let outputShape = output.value.multiArrayConstraint?.shape.map(\.intValue),
      outputShape == [1, 2, 2, inputShape[2]],
      let outputType = output.value.multiArrayConstraint?.dataType,
      [MLMultiArrayDataType.float32, .float16, .double].contains(outputType),
      let creator = description.metadata[.creatorDefinedKey] as? [String: String],
      creator["coverflow.stem_order"] == "Vocals,Instrumental",
      creator["coverflow.sample_rate"] == "44100"
    else {
      throw NativeKaraokeError.message(
        "Choose a converted stereo 44.1 kHz waveform model with [1,2,N] input, [1,2,2,N] output and Cover Flow stem-order metadata. Raw .ckpt files require the Mac processor."
      )
    }
    self.input = input.key
    self.output = output.key
    chunk = inputShape[2]
  }
  func predict(_ wave: [[Float]]) throws -> [[[Float]]] {
    let array = try MLMultiArray(shape: [1, 2, NSNumber(value: chunk)], dataType: .float32)
    let inputData = array.dataPointer.assumingMemoryBound(to: Float.self)
    let strides = array.strides.map(\.intValue)
    for channel in 0..<2 {
      for index in 0..<chunk {
        inputData[channel * strides[1] + index * strides[2]] = wave[channel][index]
      }
    }
    let provider = try MLDictionaryFeatureProvider(dictionary: [
      input: MLFeatureValue(multiArray: array)
    ])
    guard
      let output = try model.prediction(from: provider).featureValue(for: self.output)?
        .multiArrayValue, output.count == 4 * chunk,
      output.shape.map(\.intValue) == [1, 2, 2, chunk]
    else { throw NativeKaraokeError.message("The model returned incomplete stems.") }
    // MLMultiArray may use non-contiguous strides. Read its declared indices.
    if output.dataType == .float32 {
      let values = output.dataPointer.assumingMemoryBound(to: Float.self)
      let strides = output.strides.map(\.intValue)
      return (0..<2).map { stem in
        (0..<2).map { channel in
          (0..<chunk).map { values[stem * strides[1] + channel * strides[2] + $0 * strides[3]] }
        }
      }
    }
    return (0..<2).map { stem in
      (0..<2).map { channel in
        (0..<chunk).map {
          output[[0, NSNumber(value: stem), NSNumber(value: channel), NSNumber(value: $0)]]
            .floatValue
        }
      }
    }
  }
}

enum NativeKaraokeEngine {
  static func prepare(
    input: URL, output: URL, model: MobileKaraokeModel, models: URL, cache: URL,
    cancellation: NativeKaraokeCancellation, notify: @escaping @Sendable (String, Double) -> Void
  ) throws -> Int64 {
    try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    var cacheURL = cache
    var flags = URLResourceValues()
    flags.isExcludedFromBackup = true
    try? cacheURL.setResourceValues(flags)
    try cancellation.check()
    let source = try AVAudioFile(forReading: input)
    guard source.processingFormat.sampleRate == 44100, source.processingFormat.channelCount == 2,
      source.length > 0, source.length < Int64(Int.max / 64)
    else { throw NativeKaraokeError.message("Prepare stereo 44.1 kHz audio before separation.") }
    let frames = Int(source.length)
    let capacity = try? output.resourceValues(forKeys: [
      .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
    ])
    let available = max(
      capacity?.volumeAvailableCapacityForImportantUsage ?? 0,
      Int64(capacity?.volumeAvailableCapacity ?? 0))
    // Some test/file-provider volumes report zero for the advisory important-
    // usage key. Use ordinary free space too; writes still surface ENOSPC.
    if available > 0, available < Int64(frames) * 40 + 50_000_000 {
      throw NativeKaraokeError.message("This iPad needs more free space to prepare this track.")
    }
    var runtime: CFMDXRuntime?
    var waveModel: WaveformModel?
    var spectrum: MDXSpectrum?
    var gpu = true
    let chunk: Int
    let trim: Int
    if model.backend == .mdx {
      guard let parameters = model.parameters else {
        throw NativeKaraokeError.message("Missing MDX settings.")
      }
      try parameters.validate()
      spectrum = try MDXSpectrum(fft: parameters.fft, frequency: parameters.frequency)
      chunk = parameters.chunk
      trim = parameters.fft / 2
      let conversion = cache.appendingPathComponent(
        model.digest + "-"
          + SHA256.hash(data: model.parameterData).map { String(format: "%02x", $0) }.joined()
          + "-ort" + CFMDXRuntime.runtimeVersion() + "-mdx-v1", isDirectory: true)
      try FileManager.default.createDirectory(at: conversion, withIntermediateDirectories: true)
      notify("Converting or loading model for Core ML GPU", 0)
      do {
        runtime = try CFMDXRuntime(
          path: model.url(in: models).path, gpu: true, cache: conversion.path,
          frequency: parameters.frequency, time: parameters.time)
      } catch {
        gpu = false
        notify("GPU unavailable — using CPU", 0)
        runtime = try CFMDXRuntime(
          path: model.url(in: models).path, gpu: false, cache: conversion.path,
          frequency: parameters.frequency, time: parameters.time)
      }
      try cancellation.install(runtime!)
    } else {
      notify("Compiling or loading Core ML model", 0)
      waveModel = try WaveformModel(
        url: model.url(in: models),
        compiledCache: cache.appendingPathComponent(model.digest + ".mlmodelc"))
      chunk = waveModel!.chunk
      trim = chunk / 4
    }
    let step = chunk / 2
    let generated = chunk - 2 * trim
    let total = frames + trim + generated + trim - frames % generated
    let results = try ScratchFloats(
      url: output.appendingPathComponent("stems.pcm"), count: 4 * frames)
    let weights = try ScratchFloats(
      url: output.appendingPathComponent("weights.pcm"), count: frames)
    let starts = Array(stride(from: 0, to: frames + trim, by: step))
    for (number, start) in starts.enumerated() {
      try cancellation.check()
      try autoreleasepool {
        let length = min(chunk, total - start)
        let low = max(start, trim)
        let high = min(start + length, trim + frames)
        var wave = Array(repeating: [Float](repeating: 0, count: chunk), count: 2)
        if high > low {
          source.framePosition = Int64(low - trim)
          let buffer = AVAudioPCMBuffer(
            pcmFormat: source.processingFormat, frameCapacity: AVAudioFrameCount(high - low))!
          try source.read(into: buffer, frameCount: AVAudioFrameCount(high - low))
          guard Int(buffer.frameLength) == high - low, let channels = buffer.floatChannelData else {
            throw NativeKaraokeError.message("Couldn’t read all source audio.")
          }
          for channel in 0..<2 {
            for frame in 0..<(high - low) {
              let value = channels[channel][frame]
              guard value.isFinite else {
                throw NativeKaraokeError.message("The source contains invalid audio.")
              }
              wave[channel][low - start + frame] = value
            }
          }
        }
        let stems: [[[Float]]]
        if let parameters = model.parameters, let spectral = spectrum {
          var packed = spectral.encode(wave)
          for plane in 0..<4 {
            for bin in 0..<min(3, parameters.frequency) {
              for time in 0..<parameters.time {
                packed[(plane * parameters.frequency + bin) * parameters.time + time] = 0
              }
            }
          }
          func prediction() throws -> [Float] {
            let positive = try run(runtime!, input: packed)
            let negative = try run(runtime!, input: packed.map { -($0) })
            let result = zip(positive, negative).map { ($0 - $1) * 0.5 }
            guard result.allSatisfy(\.isFinite) else {
              throw NativeKaraokeError.message("Model produced non-finite audio.")
            }
            return result
          }
          let predicted: [Float]
          do { predicted = try prediction() } catch {
            try cancellation.check()
            guard gpu else { throw error }
            gpu = false
            notify("GPU unavailable — continuing on CPU", Double(number) / Double(starts.count))
            runtime = try CFMDXRuntime(
              path: model.url(in: models).path, gpu: false, cache: cache.path,
              frequency: parameters.frequency, time: parameters.time)
            try cancellation.install(runtime!)
            predicted = try prediction()
          }
          let primary = try spectral.decode(predicted, frames: chunk).map {
            $0.map { $0 * parameters.compensate }
          }
          let complement = (0..<2).map { channel in
            zip(wave[channel], primary[channel]).map { $0 - $1 }
          }
          stems =
            parameters.primary_stem == "Vocals" ? [primary, complement] : [complement, primary]
        } else {
          stems = try waveModel!.predict(wave)
        }
        guard stems.allSatisfy({ $0.allSatisfy({ $0.allSatisfy(\.isFinite) }) }) else {
          throw NativeKaraokeError.message("The model produced invalid audio.")
        }
        if high > low {
          for original in low..<high {
            let local = original - start
            let destination = original - trim
            let weight: Float =
              length > 2 ? 0.5 - 0.5 * cos(2 * Float.pi * Float(local) / Float(length - 1)) : 1
            weights[destination] += weight
            for stem in 0..<2 {
              for channel in 0..<2 {
                results[(stem * 2 + channel) * frames + destination] +=
                  stems[stem][channel][local] * weight
              }
            }
          }
        }
      }
      notify(
        gpu ? "Separating with Core ML (GPU enabled)" : "Separating on CPU",
        Double(number + 1) / Double(starts.count))
    }
    try cancellation.check()
    notify("Saving prepared audio", 1)
    var peak: Float = 0
    for index in 0..<frames {
      if index % 8192 == 0 { try cancellation.check() }
      guard weights[index] > 0 else {
        throw NativeKaraokeError.message("Some frames were not processed.")
      }
      for plane in 0..<4 {
        let value = results[plane * frames + index] / weights[index]
        guard value.isFinite else {
          throw NativeKaraokeError.message("Invalid reconstructed audio.")
        }
        peak = max(peak, abs(value))
      }
    }
    let gain = min(1, 0.98 / max(0.98, peak))
    let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
    for stem in 0..<2 {
      let file = try AVAudioFile(
        forWriting: output.appendingPathComponent(stem == 0 ? "vocals.wav" : "instrumental.wav"),
        settings: format.settings)
      for start in stride(from: 0, to: frames, by: 8192) {
        try cancellation.check()
        let count = min(8192, frames - start)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        for channel in 0..<2 {
          for frame in 0..<count {
            buffer.floatChannelData![channel][frame] =
              results[(stem * 2 + channel) * frames + start + frame] / weights[start + frame] * gain
          }
        }
        try file.write(from: buffer)
      }
    }
    return Int64(frames)
  }
  private static func run(_ model: CFMDXRuntime, input: [Float]) throws -> [Float] {
    let data = input.withUnsafeBytes { Data($0) }
    let output = try model.predict(data)
    guard output.count == input.count * 4 else {
      throw NativeKaraokeError.message("Invalid MDX output size.")
    }
    return output.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
  }
}
