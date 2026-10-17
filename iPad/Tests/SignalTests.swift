import AVFoundation
import CryptoKit
import XCTest

@testable import iPadSignal

final class SignalTests: XCTestCase {
  func testHQ5SpectralRoundTripPreservesChannelsAndEdges() throws {
    let frames = 15360
    let fft = 5120
    let spectrum = try MDXSpectrum(fft: fft, frequency: fft / 2 + 1)
    var audio = [[Float](repeating: 0, count: frames), [Float](repeating: 0, count: frames)]
    for index in 0..<frames {
      audio[0][index] = sin(Float(index) * 0.13) * 0.2
      audio[1][index] = cos(Float(index) * 0.071) * 0.15
    }
    audio[0][0] = 0.7
    audio[1][frames - 1] = -0.5
    let packed = spectrum.encode(audio)
    XCTAssertEqual(packed.count, 4 * (fft / 2 + 1) * 16)
    let restored = try spectrum.decode(packed, frames: frames)
    let maximum = (0..<2).flatMap { channel in
      (0..<frames).map { abs(audio[channel][$0] - restored[channel][$0]) }
    }.max()!
    XCTAssertLessThan(maximum, 2e-5)
  }
  func testPackedSpectrumMatchesDesktopTorchReference() throws {
    let frames = 15360
    let transform = try MDXSpectrum(fft: 5120, frequency: 2561)
    var audio = [
      (0..<frames).map { Float(($0 * 37) % 127 - 63) / 1000 },
      (0..<frames).map { Float(($0 * 53) % 113 - 56) / 1000 },
    ]
    audio[0][0] = 0.7
    audio[1][frames - 1] = -0.5
    let packed = transform.encode(audio)
    let values = try JSONDecoder().decode(
      [String: Float].self,
      from: Data(
        contentsOf: Bundle.module.url(
          forResource: "mdx-spectrum", withExtension: "json", subdirectory: "Fixtures")!))
    for (index, value) in values {
      XCTAssertEqual(packed[Int(index)!], value, accuracy: 0.001, "Packed index \(index)")
    }
  }
  func testCancellationAndNativeModelWithLocalWeightsWhenConfigured() throws {
    guard let checkpoint = ProcessInfo.processInfo.environment["IPAD_TEST_MDX_MODEL"] else {
      throw XCTSkip("Set IPAD_TEST_MDX_MODEL for native ONNX integration")
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "iPadNative-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let models = root.appendingPathComponent("Models")
    let folder = models.appendingPathComponent(id.uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let destination = folder.appendingPathComponent("Inst_HQ_5.onnx")
    try FileManager.default.copyItem(at: URL(fileURLWithPath: checkpoint), to: destination)
    let source = root.appendingPathComponent("source.wav")
    try makeWave(source)
    let original = try Data(contentsOf: source)
    let settings = MDXParameters(
      compensate: 1.01, mdx_dim_f_set: 2560, mdx_dim_t_set: 8, mdx_n_fft_scale_set: 5120,
      primary_stem: "Instrumental")
    let model = MobileKaraokeModel(
      id: id, name: "Inst_HQ_5", filename: destination.lastPathComponent,
      digest: try MobileKaraokeModel.digest(destination), parameters: settings, backend: .mdx)
    let output = root.appendingPathComponent("output")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let frames = try NativeKaraokeEngine.prepare(
      input: source, output: output, model: model, models: models,
      cache: root.appendingPathComponent("cache"), cancellation: NativeKaraokeCancellation(),
      notify: { stage, _ in print(stage) })
    XCTAssertEqual(frames, 4410)
    try KaraokeAudio(
      key: "test", trackID: UUID(), frames: frames, sampleRate: 44100, modelSHA256: model.digest,
      directory: output
    ).validate()
    XCTAssertEqual(try Data(contentsOf: source), original)
    let vocals = try samples(output.appendingPathComponent("vocals.wav"))
    let music = try samples(output.appendingPathComponent("instrumental.wav"))
    let mix = try samples(source)
    for channel in 0..<2 {
      for frame in 0..<4410 {
        XCTAssertTrue(vocals[channel][frame].isFinite)
        XCTAssertEqual(
          vocals[channel][frame] + music[channel][frame], mix[channel][frame], accuracy: 2e-5)
      }
    }
    XCTAssertEqual(try MobileKaraokeModel.uvrHash(destination), "cb790d0c913647ced70fc6b38f5bea1a")
  }
  func testCancelledWorkCannotCommitPreparedFiles() throws {
    let cancellation = NativeKaraokeCancellation()
    XCTAssertEqual(try cancellation.commit { 42 }, 42)
    cancellation.cancel()
    var committed = false
    XCTAssertThrowsError(try cancellation.check())
    XCTAssertThrowsError(try cancellation.commit { committed = true })
    XCTAssertFalse(committed)
  }
  func testCatalogOnlyDecodesTheSelectedModelProfile() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = root.appendingPathComponent("model.onnx")
    let json = root.appendingPathComponent("settings.json")
    try Data("fixture".utf8).write(to: model)
    let settings = MDXParameters(
      compensate: 1.01, mdx_dim_f_set: 2560, mdx_dim_t_set: 8, mdx_n_fft_scale_set: 5120,
      primary_stem: "Instrumental")
    let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings))
    try JSONSerialization.data(withJSONObject: [
      MobileKaraokeModel.uvrHash(model): value, "unrelated-architecture": ["other": true],
    ]).write(to: json)
    XCTAssertEqual(try MobileKaraokeModel.parameters(file: json, model: model), settings)
    try Data("{}".utf8).write(to: json)
    XCTAssertThrowsError(try MobileKaraokeModel.parameters(file: json, model: model))
  }
  func testConvertedWaveformModelPreservesFrameCountAndStemOrder() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "Waveform-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let models = root.appendingPathComponent("Models")
    let folder = models.appendingPathComponent(id.uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let fixture = Bundle.module.url(
      forResource: "SplitFixture", withExtension: "mlmodel", subdirectory: "Fixtures")!
    let weights = folder.appendingPathComponent("SplitFixture.mlmodel")
    try FileManager.default.copyItem(at: fixture, to: weights)
    let model = MobileKaraokeModel(
      id: id, name: "Fixture", filename: weights.lastPathComponent,
      digest: try MobileKaraokeModel.digest(weights), parameters: nil, backend: .coreML)
    let source = root.appendingPathComponent("source.wav")
    let output = root.appendingPathComponent("output")
    try makeWave(source)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let frames = try NativeKaraokeEngine.prepare(
      input: source, output: output, model: model, models: models,
      cache: root.appendingPathComponent("cache"), cancellation: NativeKaraokeCancellation(),
      notify: { _, _ in })
    XCTAssertEqual(frames, 4410)
    let original = try samples(source)
    let vocals = try samples(output.appendingPathComponent("vocals.wav"))
    let music = try samples(output.appendingPathComponent("instrumental.wav"))
    for channel in 0..<2 {
      for frame in 0..<4410 {
        XCTAssertEqual(vocals[channel][frame], original[channel][frame] * 0.3, accuracy: 0.0001)
        XCTAssertEqual(music[channel][frame], original[channel][frame] * 0.7, accuracy: 0.0001)
      }
    }
  }
  private func makeWave(_ url: URL) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4410)!
    buffer.frameLength = 4410
    for channel in 0..<2 {
      for index in 0..<4410 {
        buffer.floatChannelData![channel][index] = sin(Float(index) * 0.1 + Float(channel)) * 0.1
      }
    }
    try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
  }
  private func samples(_ url: URL) throws -> [[Float]] {
    let file = try AVAudioFile(forReading: url)
    let buffer = AVAudioPCMBuffer(
      pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    return (0..<2).map {
      Array(
        UnsafeBufferPointer(start: buffer.floatChannelData![$0], count: Int(buffer.frameLength)))
    }
  }
  func testReflectPaddingAndParameterValidation() throws {
    XCTAssertEqual(
      (-3...7).map { MDXSpectrum.reflected($0, length: 4) }, [3, 2, 1, 0, 1, 2, 3, 2, 1, 0, 1])
    try MDXParameters(
      compensate: 1.01, mdx_dim_f_set: 2560, mdx_dim_t_set: 8, mdx_n_fft_scale_set: 5120,
      primary_stem: "Instrumental"
    ).validate()
    XCTAssertThrowsError(
      try MDXParameters(
        compensate: .nan, mdx_dim_f_set: 2560, mdx_dim_t_set: 8, mdx_n_fft_scale_set: 5120,
        primary_stem: "Vocals"
      ).validate())
  }
}
