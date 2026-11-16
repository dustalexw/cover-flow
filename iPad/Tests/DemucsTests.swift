import AVFoundation
import XCTest

@testable import iPadSignal

/// A stand-in model: stem k is the mix scaled by `shares[k]`.
private final class ScalingModel: StemSeparating {
  let shares: [Float]
  let segment: Int
  var calls = 0
  init(shares: [Float], segment: Int) {
    self.shares = shares
    self.segment = segment
  }
  var stemCount: Int { shares.count }
  func separate(_ mix: [Float]) throws -> [Float] {
    calls += 1
    XCTAssertEqual(mix.count, 2 * segment)
    return shares.flatMap { share in mix.map { $0 * share } }
  }
}

final class DemucsTests: XCTestCase {
  func testSegmentsOverlapByAQuarterAndReachTheEnd() {
    XCTAssertEqual(DemucsSeparation.starts(frames: 10, segment: 40), [0])
    XCTAssertEqual(DemucsSeparation.starts(frames: 40, segment: 40), [0])
    XCTAssertEqual(DemucsSeparation.starts(frames: 41, segment: 40), [0, 30])
    XCTAssertEqual(DemucsSeparation.starts(frames: 100, segment: 40), [0, 30, 60])
    XCTAssertEqual(DemucsSeparation.starts(frames: 0, segment: 40), [])
    for frames in [1, 39, 40, 41, 77, 343_980 * 3 + 5] {
      let starts = DemucsSeparation.starts(frames: frames, segment: 343_980)
      XCTAssertGreaterThanOrEqual(starts.last! + 343_980, frames)
    }
  }
  func testCrossFadesSumToOne() {
    let segment = 40
    let first = DemucsSeparation.window(segment: segment, first: true, last: false)
    let middle = DemucsSeparation.window(segment: segment, first: false, last: false)
    let last = DemucsSeparation.window(segment: segment, first: false, last: true)
    XCTAssertEqual(first.first, 1)
    XCTAssertEqual(last.last, 1)
    let overlap = segment / 4
    for index in 0..<overlap {
      XCTAssertEqual(first[segment - overlap + index] + middle[index], 1, accuracy: 1e-6)
      XCTAssertEqual(middle[segment - overlap + index] + last[index], 1, accuracy: 1e-6)
    }
  }
  func testStemNamesFollowTheExports() {
    XCTAssertEqual(DemucsSeparation.stemNames(count: 4), ["drums", "bass", "other", "vocals"])
    XCTAssertEqual(DemucsSeparation.stemNames(count: 6)?.suffix(2), ["guitar", "piano"])
    XCTAssertNil(DemucsSeparation.stemNames(count: 2))
  }
  func testSeparationWritesEveryStemAndAnInstrumentalThatMatchTheMix() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
      "demucs-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
    let frames = 257
    let input = folder.appendingPathComponent("source.wav")
    var expected = [[Float]](repeating: [], count: 2)
    do {
      let file = try AVAudioFile(forWriting: input, settings: format.settings)
      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
      buffer.frameLength = AVAudioFrameCount(frames)
      for channel in 0..<2 {
        for frame in 0..<frames {
          let value = Float(sin(Double(frame) * 0.07 + Double(channel))) * 0.5
          buffer.floatChannelData![channel][frame] = value
          expected[channel].append(value)
        }
      }
      try file.write(from: buffer)
    }
    let model = ScalingModel(shares: [0.1, 0.2, 0.3, 0.4], segment: 40)
    let result = try DemucsSeparation.process(
      input: input, output: folder, model: model, cancellation: NativeKaraokeCancellation(),
      notify: { _, _ in })
    XCTAssertEqual(result.frames, Int64(frames))
    XCTAssertEqual(result.stems, ["drums", "bass", "other", "vocals"])
    XCTAssertEqual(model.calls, DemucsSeparation.starts(frames: frames, segment: 40).count)
    func read(_ name: String) throws -> [[Float]] {
      let file = try AVAudioFile(forReading: folder.appendingPathComponent(name + ".wav"))
      XCTAssertEqual(file.length, Int64(frames))
      let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(frames))!
      try file.read(into: buffer)
      return (0..<2).map { channel in (0..<frames).map { buffer.floatChannelData![channel][$0] } }
    }
    for (index, name) in result.stems.enumerated() {
      let stem = try read(name)
      for channel in 0..<2 {
        for frame in 0..<frames {
          XCTAssertEqual(stem[channel][frame], expected[channel][frame] * model.shares[index], accuracy: 1e-5)
        }
      }
    }
    let instrumental = try read("instrumental")
    for channel in 0..<2 {
      for frame in 0..<frames {
        XCTAssertEqual(instrumental[channel][frame], expected[channel][frame] * 0.6, accuracy: 1e-5)
      }
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("demucs.pcm").path))
  }
}
