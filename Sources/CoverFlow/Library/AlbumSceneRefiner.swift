import AppKit
import CoreML
import StableDiffusion

/// Refines a quilted scene with Stable Diffusion 1.5 image-to-image.
///
/// Apple's Core ML models are fixed at 512 × 512, so the scene is covered with
/// square tiles along its long side (two overlapping tiles for the 2160 × 1320
/// canvas). Each tile is repainted at about half strength, so the quilted
/// scene's colors and layout survive while textures become coherent imagery.
/// The tiles are blended back together, the quilted scene's fine detail is
/// added back on top of the upscaled result, and the cover itself is restored.
///
/// Models load on first use and unload after a short idle period, because the
/// pipeline holds roughly 2–4 GB while loaded.
final class AlbumSceneRefiner: @unchecked Sendable {
    static let shared = AlbumSceneRefiner()

    /// Input and output size of the bundled models.
    static let resolution = 512
    static let prompt = "soft abstract background extending album cover art, painterly texture, smooth gradients, cohesive colors, no text"
    static let negativePrompt = "text, letters, words, typography, watermark, logo, signature, frame, border, face, person, people, nsfw"

    /// The bundled model folder, when this build includes it and the Mac can run it well.
    static let modelURL: URL? = {
        #if arch(arm64)
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("StableDiffusion", isDirectory: true) else { return nil }
        let files = FileManager.default
        let hasUnet = files.fileExists(atPath: url.appendingPathComponent("Unet.mlmodelc").path)
            || files.fileExists(atPath: url.appendingPathComponent("UnetChunk1.mlmodelc").path)
        guard hasUnet, files.fileExists(atPath: url.appendingPathComponent("VAEEncoder.mlmodelc").path) else { return nil }
        return url
        #else
        // Intel Macs have no Neural Engine; a scene would take several minutes.
        return nil
        #endif
    }()

    static var isAvailable: Bool { modelURL != nil }

    private static let idleUnloadDelay: TimeInterval = 90

    /// All model work happens on this queue; `pipeline` and `generation` are only touched here.
    private let queue = DispatchQueue(label: "app.coverflow.scene-refiner", qos: .userInitiated)
    private var pipeline: StableDiffusionPipeline?
    private var generation = 0

    /// Returns the refined scene, or nil when the model is unavailable, generation
    /// fails or is cancelled, or the safety checker rejects a tile.
    func refine(_ scene: CGImage, cover: CGRect, seed: UInt64) async -> CGImage? {
        guard let modelURL = Self.modelURL else { return nil }
        let cancelled = RefinementCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    continuation.resume(returning: self.run(scene, cover: cover, seed: seed,
                                                            modelURL: modelURL, cancelled: cancelled))
                }
            }
        } onCancel: {
            cancelled.cancel()
        }
    }

    private func run(_ scene: CGImage, cover: CGRect, seed: UInt64, modelURL: URL,
                     cancelled: RefinementCancellation) -> CGImage? {
        generation += 1
        defer { scheduleUnload() }
        guard !cancelled.isCancelled,
              let raster = ScenePixels(image: scene, width: scene.width, height: scene.height) else { return nil }
        do {
            let pipeline = try loadedPipeline(at: modelURL)
            var refined: [(rect: CGRect, image: CGImage)] = []
            for (index, rect) in SceneRefinementLayout.tiles(width: scene.width, height: scene.height).enumerated() {
                guard !cancelled.isCancelled,
                      let crop = scene.cropping(to: rect),
                      let input = ScenePixels(image: crop, width: Self.resolution, height: Self.resolution)?.image else { return nil }
                var configuration = PipelineConfiguration(prompt: Self.prompt)
                configuration.negativePrompt = Self.negativePrompt
                configuration.startingImage = input
                // About half strength keeps the quilted layout and colors.
                configuration.strength = 0.5
                configuration.stepCount = 24
                configuration.guidanceScale = 6.5
                configuration.schedulerType = .dpmSolverMultistepScheduler
                configuration.seed = UInt32(truncatingIfNeeded: seed &+ UInt64(index))
                // Safety checking stays on: a flagged tile comes back as nil.
                let images = try pipeline.generateImages(configuration: configuration) { _ in !cancelled.isCancelled }
                guard let image = images.first ?? nil else { return nil }
                refined.append((rect, image))
            }
            return SceneRefinementCompositor.compose(scene: raster, tiles: refined, cover: cover)?.image
        } catch {
            // A failed load or prediction can leave models half loaded.
            unload()
            return nil
        }
    }

    private func loadedPipeline(at url: URL) throws -> StableDiffusionPipeline {
        if let pipeline { return pipeline }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        // On 8 GB Macs, load each model only while it runs.
        let reduceMemory = ProcessInfo.processInfo.physicalMemory <= 8 << 30
        let pipeline = try StableDiffusionPipeline(resourcesAt: url, controlNet: [], configuration: configuration,
                                                   disableSafety: false, reduceMemory: reduceMemory)
        try pipeline.loadResources()
        self.pipeline = pipeline
        return pipeline
    }

    private func scheduleUnload() {
        let current = generation
        queue.asyncAfter(deadline: .now() + Self.idleUnloadDelay) { [weak self] in
            guard let self, self.generation == current else { return }
            self.unload()
        }
    }

    private func unload() {
        pipeline?.unloadResources()
        pipeline = nil
    }
}

private final class RefinementCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

/// Square tiles that cover a scene along its long side, evenly spaced and
/// overlapping by at least a quarter of a tile so blends never meet edge to edge.
enum SceneRefinementLayout {
    static func tiles(width: Int, height: Int) -> [CGRect] {
        guard width > 0, height > 0 else { return [] }
        let side = min(width, height), long = max(width, height)
        let count = long == side ? 1 : Int((Double(long - side) / (Double(side) * 0.75)).rounded(.up)) + 1
        return (0..<count).map { index in
            let offset = count == 1 ? 0 : Int((Double(long - side) * Double(index) / Double(count - 1)).rounded())
            return width >= height ? CGRect(x: offset, y: 0, width: side, height: side)
                                   : CGRect(x: 0, y: offset, width: side, height: side)
        }
    }
}

/// Model-independent compositing, kept separate so it can be tested without the model.
enum SceneRefinementCompositor {
    /// Blends refined tiles (any size, resampled to their rectangles) into one scene,
    /// adds back the quilted scene's fine detail lost to the 512-pixel model, and
    /// restores the cover with a short feather around it.
    static func compose(scene: ScenePixels, tiles: [(rect: CGRect, image: CGImage)], cover: CGRect,
                        detail: Double = 0.6, feather: Double = 24) -> ScenePixels? {
        let width = scene.width, height = scene.height
        guard !tiles.isEmpty else { return nil }
        var sum = [Double](repeating: 0, count: width * height * 3)
        var weights = [Double](repeating: 0, count: width * height)
        let horizontal = width >= height
        for tile in tiles {
            let rect = tile.rect.integral
            let tw = Int(rect.width), th = Int(rect.height), tx = Int(rect.minX), ty = Int(rect.minY)
            guard tw > 0, th > 0, let pixels = ScenePixels(image: tile.image, width: tw, height: th) else { return nil }
            for y in 0..<th { for x in 0..<tw {
                let ox = tx + x, oy = ty + y
                guard ox >= 0, oy >= 0, ox < width, oy < height else { continue }
                // Tent weights along the long side blend overlapping tiles without a seam.
                let along = horizontal ? x : y, length = horizontal ? tw : th
                let weight = Double(min(along, length - 1 - along) + 1)
                let si = (y * tw + x) * 4, oi = oy * width + ox
                for c in 0..<3 { sum[oi * 3 + c] += Double(pixels.bytes[si + c]) * weight }
                weights[oi] += weight
            } }
        }
        // The model sees each tile at 512 pixels, so detail finer than that is
        // taken from the quilted scene: scene minus its 512-equivalent blur.
        let side = Double(min(width, height))
        let scale = min(1, Double(AlbumSceneRefiner.resolution) / side)
        guard let sceneImage = scene.image,
              let small = ScenePixels(image: sceneImage, width: max(1, Int(Double(width) * scale)),
                                      height: max(1, Int(Double(height) * scale))),
              let smallImage = small.image,
              let blurred = ScenePixels(image: smallImage, width: width, height: height) else { return nil }
        var output = ScenePixels(width: width, height: height)
        let left = Double(cover.minX), right = Double(cover.maxX)
        let top = Double(cover.minY), bottom = Double(cover.maxY)
        for y in 0..<height { for x in 0..<width {
            let index = y * width + x, bi = index * 4
            // Distance outside the cover: 0 inside, growing outward.
            let px = Double(x) + 0.5, py = Double(y) + 0.5
            let dx = max(left - px, px - right, 0)
            let dy = max(top - py, py - bottom, 0)
            let keepCover = 1 - ((dx * dx + dy * dy).squareRoot() / feather).clamped(0, 1)
            for c in 0..<3 {
                let original = Double(scene.bytes[bi + c])
                let refined: Double
                if weights[index] > 0 {
                    let fine = original - Double(blurred.bytes[bi + c])
                    refined = sum[index * 3 + c] / weights[index] + fine * detail
                } else {
                    refined = original
                }
                let value = refined * (1 - keepCover) + original * keepCover
                output.bytes[bi + c] = UInt8(value.rounded().clamped(0, 255))
            }
            output.bytes[bi + 3] = 255
        } }
        return output
    }
}
