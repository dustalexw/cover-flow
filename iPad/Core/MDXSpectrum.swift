import Accelerate
import Foundation

struct MDXParameters: Codable, Equatable, Sendable {
  let compensate: Float
  let mdx_dim_f_set: Int
  let mdx_dim_t_set: Int
  let mdx_n_fft_scale_set: Int
  let primary_stem: String
  var frequency: Int { mdx_dim_f_set }
  var time: Int { 1 << mdx_dim_t_set }
  var fft: Int { mdx_n_fft_scale_set }
  var chunk: Int { 1024 * (time - 1) }
  func validate() throws {
    guard (2048...32768).contains(fft), fft % 2 == 0, (4...10).contains(mdx_dim_t_set),
      (1...(fft / 2 + 1)).contains(frequency), chunk > fft,
      compensate.isFinite, compensate > 0, compensate <= 4,
      ["Vocals", "Instrumental"].contains(primary_stem)
    else {
      throw NativeKaraokeError.message("Choose matching UVR vocal/instrumental MDX settings.")
    }
  }
}
enum NativeKaraokeError: LocalizedError {
  case message(String)
  case needsMDXSettings
  var errorDescription: String? {
    switch self {
    case .message(let value): return value
    case .needsMDXSettings: return "This model needs its matching UVR JSON settings."
    }
  }
}

/// Float32 complex DFT with the same stereo packing, Hann window, centering and
/// reflection padding as the desktop torch.stft/istft path. Supports FFT 5120.
final class MDXSpectrum {
  let fft: Int, frequency: Int, hop = 1024
  private let forward: vDSP.DFT<Float>
  private let inverse: vDSP.DFT<Float>
  private let window: [Float]
  init(fft: Int, frequency: Int) throws {
    guard fft >= 2048, frequency > 0, frequency <= fft / 2 + 1,
      let forward = vDSP.DFT(
        count: fft, direction: .forward, transformType: .complexComplex, ofType: Float.self),
      let inverse = vDSP.DFT(
        count: fft, direction: .inverse, transformType: .complexComplex, ofType: Float.self)
    else { throw NativeKaraokeError.message("This model uses an unsupported FFT size.") }
    self.fft = fft
    self.frequency = frequency
    self.forward = forward
    self.inverse = inverse
    window = (0..<fft).map { 0.5 - 0.5 * cos(2 * Float.pi * Float($0) / Float(fft)) }
  }
  static func reflected(_ index: Int, length: Int) -> Int {
    guard length > 1 else { return 0 }
    let period = 2 * (length - 1)
    let value = ((index % period) + period) % period
    return value < length ? value : period - value
  }
  func encode(_ audio: [[Float]]) -> [Float] {
    let frames = audio[0].count
    let time = frames / hop + 1
    var result = [Float](repeating: 0, count: 4 * frequency * time)
    let zeros = [Float](repeating: 0, count: fft)
    for channel in 0..<2 {
      for column in 0..<time {
        let start = column * hop - fft / 2
        let real = (0..<fft).map {
          audio[channel][Self.reflected(start + $0, length: frames)] * window[$0]
        }
        let spectrum = forward.transform(inputReal: real, inputImaginary: zeros)
        for bin in 0..<frequency {
          result[(channel * 2 * frequency + bin) * time + column] = spectrum.real[bin]
          result[((channel * 2 + 1) * frequency + bin) * time + column] = spectrum.imaginary[bin]
        }
      }
    }
    return result
  }
  func decode(_ spectrum: [Float], frames: Int) throws -> [[Float]] {
    let time = frames / hop + 1
    guard spectrum.count == 4 * frequency * time else {
      throw NativeKaraokeError.message("Incorrect model output dimensions.")
    }
    var result = Array(repeating: [Float](repeating: 0, count: frames), count: 2)
    var weights = [Float](repeating: 0, count: frames)
    for column in 0..<time {
      let start = column * hop - fft / 2
      let low = max(0, -start)
      let high = min(fft, frames - start)
      if low < high {
        for index in low..<high { weights[start + index] += window[index] * window[index] }
      }
      for channel in 0..<2 {
        var real = [Float](repeating: 0, count: fft)
        var imaginary = real
        for bin in 0..<frequency {
          real[bin] = spectrum[(channel * 2 * frequency + bin) * time + column]
          imaginary[bin] = spectrum[((channel * 2 + 1) * frequency + bin) * time + column]
        }
        for bin in (fft / 2 + 1)..<fft {
          real[bin] = real[fft - bin]
          imaginary[bin] = -imaginary[fft - bin]
        }
        let wave = inverse.transform(inputReal: real, inputImaginary: imaginary).real
        if low < high {
          for index in low..<high {
            result[channel][start + index] += wave[index] * window[index] / Float(fft)
          }
        }
      }
    }
    for frame in 0..<frames {
      guard weights[frame] > 0 else {
        throw NativeKaraokeError.message("Incomplete reconstructed audio.")
      }
      for channel in 0..<2 { result[channel][frame] /= weights[frame] }
    }
    return result
  }
}
