import AppKit
import SwiftUI
import CProjectM

struct MilkDropSurface: NSViewRepresentable {
    @ObservedObject var controller: VisualizerController
    func makeNSView(context: Context) -> NSView {
        if let view = MilkDropGLView(controller: controller) { return view }
        DispatchQueue.main.async { controller.error = "This display couldn’t create a visualizer context." }
        return NSView()
    }
    func updateNSView(_ view: NSView, context: Context) { (view as? MilkDropGLView)?.updatePreset() }
    static func dismantleNSView(_ view: NSView, coordinator: ()) { (view as? MilkDropGLView)?.shutdown() }
}

@MainActor
final class MilkDropGLView: NSOpenGLView {
    private weak var controller: VisualizerController?
    private var visualizer: OpaquePointer?
    private var timer: Timer?
    private var loadedRevision = -1
    private var audio = Array(repeating: Float(0), count: 8192)
    private var lastSize = NSSize.zero
    private var lastAudioAt = Date.distantPast

    init?(controller: VisualizerController) {
        self.controller = controller
        let attributes: [NSOpenGLPixelFormatAttribute] = [
            UInt32(NSOpenGLPFAOpenGLProfile), UInt32(NSOpenGLProfileVersion4_1Core),
            UInt32(NSOpenGLPFAAccelerated), UInt32(NSOpenGLPFADoubleBuffer),
            UInt32(NSOpenGLPFAColorSize), 24, UInt32(NSOpenGLPFAAlphaSize), 8, 0
        ]
        guard let format = NSOpenGLPixelFormat(attributes: attributes) else { return nil }
        super.init(frame: .zero, pixelFormat: format)
        wantsBestResolutionOpenGLSurface = true
        setAccessibilityLabel("MilkDrop music visualizer")
        setAccessibilityRole(.image)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func prepareOpenGL() {
        super.prepareOpenGL()
        guard visualizer == nil else { return }
        guard openGLContext != nil else { report("This display couldn’t create a visualizer context."); return }
        openGLContext?.makeCurrentContext()
        var interval: GLint = 1
        openGLContext?.setValues(&interval, for: .swapInterval)
        let library = Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/libprojectM-4.dylib")
        visualizer = cf_visualizer_create(library.path)
        if let message = cf_visualizer_error(visualizer), !String(cString: message).isEmpty {
            report(String(cString: message))
        }
        updatePreset()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        guard window != nil else { timer = nil; return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.renderFrame() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func updatePreset() {
        guard let controller, let visualizer, loadedRevision != controller.revision, let preset = controller.selected,
              bounds.width > 0, bounds.height > 0 else { return }
        openGLContext?.makeCurrentContext()
        let size = convertToBacking(bounds).size
        cf_visualizer_resize(visualizer, max(1, Int(size.width)), max(1, Int(size.height)))
        let transition = loadedRevision >= 0
        loadedRevision = controller.revision
        if !cf_visualizer_load(visualizer, preset.url.path, transition) {
            report(String(cString: cf_visualizer_error(visualizer)))
        }
    }

    private func renderFrame() {
        guard let window, window.isVisible, !window.isMiniaturized,
              window.occlusionState.contains(.visible), controller?.isOpen == true else { return }
        controller?.tick()
        updatePreset()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let visualizer, let controller, bounds.width > 0, bounds.height > 0 else { return }
        openGLContext?.makeCurrentContext()
        let backing = convertToBacking(bounds).size
        let size = NSSize(width: max(1, backing.width), height: max(1, backing.height))
        if size != lastSize {
            openGLContext?.update()
            cf_visualizer_resize(visualizer, Int(size.width), Int(size.height))
            lastSize = size
        }
        updatePreset()
        audio.withUnsafeMutableBufferPointer { samples in
            var frames = controller.player.visualizerAudio.drain(into: samples)
            if frames > 0 { lastAudioAt = Date() }
            if !controller.player.isPlaying || controller.player.isBuffering || Date().timeIntervalSince(lastAudioAt) > 0.12 {
                frames = 1024
                for i in 0..<(frames * 2) { samples[i] = 0 }
            }
            cf_visualizer_render(visualizer, samples.baseAddress, UInt32(frames))
        }
        openGLContext?.flushBuffer()
        let message = String(cString: cf_visualizer_error(visualizer))
        if !message.isEmpty, controller.error != message { report(message) }
    }

    private func report(_ message: String) {
        DispatchQueue.main.async { [weak self] in self?.controller?.error = message }
    }
    func shutdown() {
        timer?.invalidate()
        timer = nil
        openGLContext?.makeCurrentContext()
        cf_visualizer_destroy(visualizer)
        visualizer = nil
    }
}
