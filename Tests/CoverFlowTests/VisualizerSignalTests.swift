import XCTest
import Metal
import AppKit
@testable import CoverFlow

final class VisualizerSignalTests: XCTestCase {
    private func tone(_ frequency: Double, amplitude: Float = 0.2, inverted: Bool = false) -> [Float] {
        (0..<2048).flatMap { index -> [Float] in
            let value = amplitude * sin(2 * Float.pi * Float(frequency) * Float(index) / 48_000)
            return [value, inverted ? -value : value]
        }
    }
    private func feed(_ samples: [Float], into signal: VisualizerSignal, response: Float = 1.25, playing: Bool = true, dt: Double = 1.0 / 60) {
        samples.withUnsafeBufferPointer { signal.update($0, frames: samples.count / 2, elapsed: dt, playing: playing, response: response) }
    }
    func testBassAndTrebleDriveDifferentFrequencyBands() {
        let bass = VisualizerSignal(), treble = VisualizerSignal()
        for _ in 0..<8 { feed(tone(70), into: bass); feed(tone(8_000), into: treble) }
        let bassPeak = bass.bands.indices.max { bass.bands[$0] < bass.bands[$1] }!
        let treblePeak = treble.bands.indices.max { treble.bands[$0] < treble.bands[$1] }!
        XCTAssertLessThan(bassPeak, treblePeak - 20)
        XCTAssertGreaterThan(bass.bass, bass.treble)
        XCTAssertGreaterThan(treble.treble, treble.bass)
    }
    func testOppositePhaseStereoAndQuietRecordingsRemainReactive() {
        let inverted = VisualizerSignal()
        for _ in 0..<8 { feed(tone(400, inverted: true), into: inverted) }
        XCTAssertGreaterThan(inverted.bands.max()!, 0.5)
        XCTAssertGreaterThan(inverted.wave.map(abs).max()!, 0.1)
        let low = VisualizerSignal(), high = VisualizerSignal()
        let samples = tone(400, amplitude: 0.004)
        for _ in 0..<20 { feed(samples, into: low, response: 0.5); feed(samples, into: high, response: 2.5) }
        XCTAssertGreaterThan(high.level, low.level * 3)
        XCTAssertGreaterThan(high.bands.max()!, 0.2)
    }
    func testDisplayFramesBetweenAudioCallbacksDoNotInsertSilence() {
        let signal = VisualizerSignal()
        feed(tone(100), into: signal)
        let level = signal.level
        feed([], into: signal)
        XCTAssertEqual(signal.level, level)
        for _ in 0..<40 { feed([], into: signal) }
        XCTAssertLessThan(signal.level, level * 0.05)
        XCTAssertLessThan(signal.wave.map(abs).max()!, 0.05)
    }
    func testPauseDecayIsIndependentOfDisplayFrameRate() {
        let slow = VisualizerSignal(), fast = VisualizerSignal()
        for _ in 0..<8 { feed(tone(100), into: slow); feed(tone(100), into: fast) }
        for _ in 0..<15 { feed([], into: slow, playing: false, dt: 1.0 / 30) }
        for _ in 0..<60 { feed([], into: fast, playing: false, dt: 1.0 / 120) }
        XCTAssertEqual(slow.level, fast.level, accuracy: 0.0001)
        XCTAssertEqual(slow.bass, fast.bass, accuracy: 0.0001)
    }
    func testSilenceAndInvalidSamplesRemainFiniteAndDark() {
        let signal = VisualizerSignal()
        feed([.nan, .infinity, -.infinity, 0], into: signal)
        XCTAssertEqual(signal.level, 0)
        XCTAssertTrue(signal.bands.allSatisfy { $0 == 0 })
        XCTAssertTrue(signal.wave.allSatisfy { $0.isFinite && $0 == 0 })
    }
    @MainActor
    func testMetalStylesCompileAndRespondToAudio() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw XCTSkip("The test process has no access to a Metal device.")
        }
        let source = try MetalVisualizerRenderer.shaderSource()
        let library = try device.makeLibrary(source: source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "visualizerVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "visualizerFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let capture = ProcessInfo.processInfo.environment["VISUALIZER_CAPTURE_DIR"]
        let width = capture == nil ? 96 : 1280, height = capture == nil ? 64 : 720
        func render(style: Int, active: Bool) throws -> [UInt8] {
            let info = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: false)
            info.usage = .renderTarget; info.storageMode = .shared
            let texture = try XCTUnwrap(device.makeTexture(descriptor: info))
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
            let value: Float = active ? 0.8 : 0
            let uniforms: [Float] = [Float(width),Float(height),1,Float(style),value,value,value,value,value,1,0,0]
            let bands = (0..<64).map { value * (0.2 + 0.8 * abs(sin(Float($0) * 0.13))) * exp(-Float($0) * 0.01) }
            let wave = (0..<512).map { active ? sin(Float($0) * 0.1) * 0.5 : 0 }
            encoder.setRenderPipelineState(pipeline)
            uniforms.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
            bands.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
            wave.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 2) }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3); encoder.endEncoding()
            command.commit(); command.waitUntilCompleted()
            XCTAssertNil(command.error)
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            texture.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0,0,width,height), mipmapLevel: 0)
            if active, let capture {
                let folder = URL(fileURLWithPath: capture)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32)!
                let output = bitmap.bitmapData!
                for i in stride(from: 0, to: pixels.count, by: 4) {
                    output[i] = pixels[i+2]; output[i+1] = pixels[i+1]; output[i+2] = pixels[i]; output[i+3] = pixels[i+3]
                }
                try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("\(VisualizerStyle(rawValue: style)!.title).png"))
            }
            return pixels
        }
        for style in VisualizerStyle.allCases {
            let quiet = try render(style: style.rawValue, active: false)
            let active = try render(style: style.rawValue, active: true)
            XCTAssertNotEqual(quiet, active, style.title)
            XCTAssertTrue(active.enumerated().contains { $0.offset % 4 != 3 && $0.element > 40 })
        }
    }
}
