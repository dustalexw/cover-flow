import MetalKit
import SwiftUI

#if os(macOS)
struct NativeVisualizerSurface: NSViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let audio: VisualizerAudioBuffer
    var playing: Bool
    var style: VisualizerStyle
    var response: Float
    var highQuality: Bool
    var onError: (String) -> Void
    func makeCoordinator() -> MetalVisualizerRenderer { MetalVisualizerRenderer(audio: audio) }
    func makeNSView(context: Context) -> MTKView { makeView(renderer: context.coordinator) }
    func updateNSView(_ view: MTKView, context: Context) { configure(view, renderer: context.coordinator) }
    static func dismantleNSView(_ view: MTKView, coordinator: MetalVisualizerRenderer) { view.isPaused = true; view.delegate = nil }
}
#else
struct NativeVisualizerSurface: UIViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let audio: VisualizerAudioBuffer
    var playing: Bool
    var style: VisualizerStyle
    var response: Float
    var highQuality: Bool
    var onError: (String) -> Void
    func makeCoordinator() -> MetalVisualizerRenderer { MetalVisualizerRenderer(audio: audio) }
    func makeUIView(context: Context) -> MTKView { makeView(renderer: context.coordinator) }
    func updateUIView(_ view: MTKView, context: Context) { configure(view, renderer: context.coordinator) }
    static func dismantleUIView(_ view: MTKView, coordinator: MetalVisualizerRenderer) { view.isPaused = true; view.delegate = nil }
}
#endif

extension NativeVisualizerSurface {
    @MainActor fileprivate func makeView(renderer: MetalVisualizerRenderer) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.clearColor = MTLClearColorMake(0.003, 0.006, 0.016, 1)
        view.framebufferOnly = true
        view.autoResizeDrawable = true
        view.preferredFramesPerSecond = 60
        do { try renderer.prepare(view) }
        catch { DispatchQueue.main.async { onError(error.localizedDescription) } }
        configure(view, renderer: renderer)
        view.delegate = renderer
        return view
    }
    @MainActor fileprivate func configure(_ view: MTKView, renderer: MetalVisualizerRenderer) {
        renderer.playing = playing; renderer.style = style; renderer.response = response
        renderer.reduceMotion = reduceMotion
        view.preferredFramesPerSecond = renderer.reduceMotion ? 15 : (highQuality ? 60 : 30)
    }
}

@MainActor
final class MetalVisualizerRenderer: NSObject, MTKViewDelegate {
    private struct Uniforms {
        var size: SIMD2<Float>
        var time: Float
        var style: Float
        var audio: SIMD4<Float>
        var onset: Float
        var motion: Float
        var padding = SIMD2<Float>.zero
    }
    private let audio: VisualizerAudioBuffer
    private let signal = VisualizerSignal()
    private var samples = [Float](repeating: 0, count: 8192)
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private let inFlight = DispatchSemaphore(value: 3)
    private var lastTime = CACurrentMediaTime()
    private var animationTime: Double = 0
    var playing = false
    var style = VisualizerStyle.pulse
    var response: Float = 1.25
    var reduceMotion = false

    init(audio: VisualizerAudioBuffer) { self.audio = audio }

    static func shaderSource() throws -> String {
        #if os(macOS)
        let url = Bundle.module.url(forResource: "Visualizer", withExtension: "metal", subdirectory: "Shaders")
        #else
        let url = Bundle.main.url(forResource: "Visualizer", withExtension: "metal")
        #endif
        guard let url else { throw NSError(domain: "CoverFlow.Visualizer", code: 1,
                                            userInfo: [NSLocalizedDescriptionKey: "The visualizer shader is missing. Rebuild the app."]) }
        return try String(contentsOf: url, encoding: .utf8)
    }

    func prepare(_ view: MTKView) throws {
        guard let device = view.device, let queue = device.makeCommandQueue() else {
            throw NSError(domain: "CoverFlow.Visualizer", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Metal rendering is unavailable on this display."])
        }
        let library = try device.makeLibrary(source: Self.shaderSource(), options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "visualizerVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "visualizerFragment")
        descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        self.pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        self.queue = queue
    }
    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { }
    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { render(view) }
    }
    private func render(_ view: MTKView) {
        #if os(macOS)
        guard let window = view.window, window.isVisible, !window.isMiniaturized,
              window.occlusionState.contains(.visible) else { return }
        #endif
        guard let queue, let pipeline, inFlight.wait(timeout: .now()) == .success else { return }
        guard let drawable = view.currentDrawable, let pass = view.currentRenderPassDescriptor,
              let command = queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            inFlight.signal(); return
        }
        let now = CACurrentMediaTime(), elapsed = min(0.1, now - lastTime)
        lastTime = now
        if playing { animationTime += elapsed }
        samples.withUnsafeMutableBufferPointer { pointer in
            let frames = audio.drain(into: pointer)
            signal.update(UnsafeBufferPointer(pointer), frames: frames, elapsed: elapsed, playing: playing, response: response)
        }
        var uniforms = Uniforms(size: SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height)),
                                time: Float(animationTime), style: Float(style.rawValue),
                                audio: SIMD4(signal.bass, signal.mid, signal.treble, signal.level),
                                onset: signal.onset, motion: reduceMotion ? 0 : 1)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        signal.bands.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
        signal.wave.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 2) }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        let semaphore = inFlight
        command.addCompletedHandler { _ in semaphore.signal() }
        command.present(drawable); command.commit()
    }
}
