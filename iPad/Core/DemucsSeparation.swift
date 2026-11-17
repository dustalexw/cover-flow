import AVFoundation
import Foundation

#if canImport(NativeMDX)
  import NativeMDX
#endif

/// A model that splits one stereo segment into stems.
protocol StemSeparating: AnyObject {
  var stemCount: Int { get }
  var segment: Int { get }
  /// `mix` is 2 × segment floats, channel-major. Returns stemCount × 2 × segment floats.
  func separate(_ mix: [Float]) throws -> [Float]
}

extension CFDemucsRuntime: StemSeparating {
  func separate(_ mix: [Float]) throws -> [Float] {
    let data = try predict(mix.withUnsafeBytes { Data($0) })
    return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
  }
}

/// HTDemucs on iPhone and iPad: the same stems the Mac's Demucs prepares, from the
/// ONNX export of htdemucs (4 stems) or htdemucs_6s (6 stems).
enum DemucsSeparation {
  /// Output order of the HTDemucs exports.
  static func stemNames(count: Int) -> [String]? {
    switch count {
    case 4: return ["drums", "bass", "other", "vocals"]
    case 6: return ["drums", "bass", "other", "vocals", "guitar", "piano"]
    default: return nil
    }
  }

  /// Segment starts: segments overlap by a quarter, and the last one reaches the end.
  static func starts(frames: Int, segment: Int) -> [Int] {
    guard frames > 0, segment > 0 else { return [] }
    let stride = segment - segment / 4
    var result = [0]
    while result.last! + segment < frames { result.append(result.last! + stride) }
    return result
  }

  /// Linear cross-fades over the overlap, so overlapping weights sum to one. The
  /// track's first and last segments keep full weight at the track's edges.
  static func window(segment: Int, first: Bool, last: Bool) -> [Float] {
    let overlap = segment / 4
    var window = [Float](repeating: 1, count: segment)
    guard overlap > 1 else { return window }
    for index in 0..<overlap {
      let fade = Float(index) / Float(overlap - 1)
      if !first { window[index] = fade }
      if !last { window[segment - 1 - index] = fade }
    }
    return window
  }

  /// Separates `input` (stereo 44.1 kHz) into `<stem>.wav` files plus `vocals.wav`
  /// and `instrumental.wav` (all stems except vocals) in `output`.
  static func process(
    input: URL, output: URL, model: StemSeparating, cancellation: NativeKaraokeCancellation,
    notify: @escaping @Sendable (String, Double) -> Void
  ) throws -> (frames: Int64, stems: [String]) {
    guard let names = stemNames(count: model.stemCount), model.segment > 4 else {
      throw NativeKaraokeError.message("Choose a 4-stem or 6-stem HTDemucs model.")
    }
    let source = try AVAudioFile(forReading: input)
    guard source.processingFormat.sampleRate == 44100, source.processingFormat.channelCount == 2,
      source.length > 0, source.length < Int64(Int.max / 64)
    else { throw NativeKaraokeError.message("Prepare stereo 44.1 kHz audio before separation.") }
    let frames = Int(source.length)
    let segment = model.segment
    let stems = names.count
    let results = try ScratchFloats(
      url: output.appendingPathComponent("demucs.pcm"), count: stems * 2 * frames)
    let weights = try ScratchFloats(
      url: output.appendingPathComponent("weights.pcm"), count: frames)
    let segments = Self.starts(frames: frames, segment: segment)
    let buffer = AVAudioPCMBuffer(
      pcmFormat: source.processingFormat, frameCapacity: AVAudioFrameCount(segment))!
    for (number, start) in segments.enumerated() {
      try cancellation.check()
      try autoreleasepool {
        let length = min(segment, frames - start)
        source.framePosition = Int64(start)
        buffer.frameLength = 0
        try source.read(into: buffer, frameCount: AVAudioFrameCount(length))
        guard Int(buffer.frameLength) == length, let channels = buffer.floatChannelData else {
          throw NativeKaraokeError.message("Couldn’t read all source audio.")
        }
        var mix = [Float](repeating: 0, count: 2 * segment)
        for channel in 0..<2 {
          for frame in 0..<length {
            let value = channels[channel][frame]
            guard value.isFinite else {
              throw NativeKaraokeError.message("The source contains invalid audio.")
            }
            mix[channel * segment + frame] = value
          }
        }
        let separated = try model.separate(mix)
        guard separated.count == stems * 2 * segment else {
          throw NativeKaraokeError.message("The Demucs model returned unexpected stems.")
        }
        let fades = Self.window(segment: segment, first: number == 0, last: number == segments.count - 1)
        for frame in 0..<length {
          let weight = fades[frame]
          weights[start + frame] += weight
          for plane in 0..<(stems * 2) {
            let value = separated[plane * segment + frame]
            guard value.isFinite else {
              throw NativeKaraokeError.message("The model produced invalid audio.")
            }
            results[plane * frames + start + frame] += value * weight
          }
        }
      }
      notify(
        "Separating \(stems) stems on this device", Double(number + 1) / Double(segments.count) * 0.95)
    }
    try cancellation.check()
    notify("Saving stems", 0.96)
    // Shared gain keeps every stem and their sums from clipping, like the Mac.
    let vocals = names.firstIndex(of: "vocals")!
    var peak: Float = 0
    for index in 0..<frames {
      if index % 16384 == 0 { try cancellation.check() }
      guard weights[index] > 0 else {
        throw NativeKaraokeError.message("Some frames were not processed.")
      }
      let scale = 1 / weights[index]
      for channel in 0..<2 {
        var instrumental: Float = 0
        var mix: Float = 0
        for stem in 0..<stems {
          let value = results[(stem * 2 + channel) * frames + index] * scale
          peak = max(peak, abs(value))
          mix += value
          if stem != vocals { instrumental += value }
        }
        peak = max(peak, abs(instrumental), abs(mix))
      }
    }
    let gain = min(1, 0.98 / max(0.98, peak))
    let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
    func write(_ name: String, sample: (Int, Int) -> Float) throws {
      let file = try AVAudioFile(
        forWriting: output.appendingPathComponent(name + ".wav"), settings: format.settings)
      let block = 8192
      let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(block))!
      for start in stride(from: 0, to: frames, by: block) {
        try cancellation.check()
        let count = min(block, frames - start)
        out.frameLength = AVAudioFrameCount(count)
        for channel in 0..<2 {
          for frame in 0..<count {
            out.floatChannelData![channel][frame] = sample(channel, start + frame) * gain
          }
        }
        try file.write(from: out)
      }
    }
    for (stem, name) in names.enumerated() {
      try write(name) { channel, index in
        results[(stem * 2 + channel) * frames + index] / weights[index]
      }
    }
    try write("instrumental") { channel, index in
      var sum: Float = 0
      for stem in 0..<stems where stem != vocals {
        sum += results[(stem * 2 + channel) * frames + index]
      }
      return sum / weights[index]
    }
    try? FileManager.default.removeItem(at: output.appendingPathComponent("demucs.pcm"))
    try? FileManager.default.removeItem(at: output.appendingPathComponent("weights.pcm"))
    notify("Stems ready", 1)
    return (Int64(frames), names)
  }
}
