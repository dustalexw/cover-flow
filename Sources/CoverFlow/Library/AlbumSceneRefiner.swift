import AppKit
import CoreML
import StableDiffusion

/// The result of a refinement: the refined scene, or why the quilted scene is used instead.
enum SceneRefinementOutcome {
    case refined(CGImage)
    case failed(String)
}

/// Generation parameters for each refinement style.
struct SceneRefinementSettings: Equatable {
    var prompt: String
    var negativePrompt: String
    /// Image-to-image strength: how much of the starting image is repainted.
    var strength: Float
    var stepCount: Int
    var guidanceScale: Float
    /// How much of the quilted scene's fine texture is added back on top.
    var detail: Double
    /// How far (in scene pixels) the restored cover fades into the refined surroundings.
    var feather: Double
    /// How strongly the starting image echoes the cover itself (mirrored outward).
    var coverEcho: Double

    private static let baseNegative = "text, letters, words, typography, watermark, logo, signature, frame, border, face, person, people, nsfw"

    static func settings(for style: SceneRefinementStyle, colors: [String]) -> SceneRefinementSettings {
        let palette = colors.isEmpty ? "" : ", color palette of \(colors.joined(separator: ", "))"
        switch style {
        case .subtle:
            return SceneRefinementSettings(
                prompt: "soft abstract background extending album cover art, painterly texture, cohesive colors\(palette), no text",
                negativePrompt: baseNegative,
                strength: 0.5, stepCount: 24, guidanceScale: 6.5, detail: 0.6, feather: 24, coverEcho: 0)
        case .ornate:
            return SceneRefinementSettings(
                prompt: "ornate decorative illustration continuing the album cover artwork, intricate filigree, flourishes and patterns, rich painterly detail, art nouveau, elegant, highly detailed\(palette), no text",
                negativePrompt: baseNegative + ", plain, flat, empty, simple gradient, blurry, low detail, washed out",
                strength: 0.78, stepCount: 30, guidanceScale: 8, detail: 0.12, feather: 40, coverEcho: 0.55)
        }
    }
}

/// Refines a quilted scene with Stable Diffusion 1.5 image-to-image.
///
/// Apple's Core ML models are fixed at 512 × 512, so the scene is covered with
/// square tiles along its long side (two overlapping tiles for the 2160 × 1320
/// canvas). For the ornate style, the starting image first echoes the cover
/// outward (mirrored across its edges), so every tile sees the cover's own
/// imagery and the model continues it; the prompt names the cover's colors.
/// The tiles are blended back together, a little of the quilted scene's fine
/// detail is added back, and the cover itself is restored with a soft edge.
///
/// Models load on first use and unload after a short idle period, because the
/// pipeline holds roughly 2–4 GB while loaded.
final class AlbumSceneRefiner: @unchecked Sendable {
    static let shared = AlbumSceneRefiner()

    /// Input and output size of the bundled models.
    static let resolution = 512

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
    static let unavailableReason = "Stable Diffusion isn’t included in this build or isn’t supported on this Mac."

    private static let idleUnloadDelay: TimeInterval = 90

    /// All model work happens on this queue; `pipeline` and `generation` are only touched here.
    private let queue = DispatchQueue(label: "app.coverflow.scene-refiner", qos: .userInitiated)
    private var pipeline: StableDiffusionPipeline?
    private var generation = 0

    func refine(_ scene: CGImage, cover: CGRect, seed: UInt64, style: SceneRefinementStyle) async -> SceneRefinementOutcome {
        guard let modelURL = Self.modelURL else { return .failed(Self.unavailableReason) }
        let cancelled = RefinementCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    continuation.resume(returning: self.run(scene, cover: cover, seed: seed, style: style,
                                                            modelURL: modelURL, cancelled: cancelled))
                }
            }
        } onCancel: {
            cancelled.cancel()
        }
    }

    private func run(_ scene: CGImage, cover: CGRect, seed: UInt64, style: SceneRefinementStyle, modelURL: URL,
                     cancelled: RefinementCancellation) -> SceneRefinementOutcome {
        generation += 1
        defer { scheduleUnload() }
        guard !cancelled.isCancelled else { return .failed("Cancelled.") }
        guard let raster = ScenePixels(image: scene, width: scene.width, height: scene.height) else {
            return .failed("The scene couldn’t be read.")
        }
        let settings = SceneRefinementSettings.settings(for: style, colors: SceneColorWords.describe(raster, cover: cover))
        let start = settings.coverEcho > 0
            ? SceneRefinementCompositor.echoCover(scene: raster, cover: cover, amount: settings.coverEcho)
            : raster
        guard let startImage = start.image else { return .failed("The scene couldn’t be prepared.") }
        do {
            let pipeline = try loadedPipeline(at: modelURL)
            var refined: [(rect: CGRect, image: CGImage)] = []
            for (index, rect) in SceneRefinementLayout.tiles(width: scene.width, height: scene.height).enumerated() {
                guard !cancelled.isCancelled else { return .failed("Cancelled.") }
                guard let crop = startImage.cropping(to: rect),
                      let input = ScenePixels(image: crop, width: Self.resolution, height: Self.resolution)?.image else {
                    return .failed("The scene couldn’t be prepared.")
                }
                var configuration = PipelineConfiguration(prompt: settings.prompt)
                configuration.negativePrompt = settings.negativePrompt
                configuration.startingImage = input
                configuration.strength = settings.strength
                configuration.stepCount = settings.stepCount
                configuration.guidanceScale = settings.guidanceScale
                configuration.schedulerType = .dpmSolverMultistepScheduler
                configuration.seed = UInt32(truncatingIfNeeded: seed &+ UInt64(index))
                // Safety checking stays on: a flagged tile comes back as nil.
                let images = try pipeline.generateImages(configuration: configuration) { _ in !cancelled.isCancelled }
                if images.isEmpty { return .failed("Cancelled.") }
                guard let image = images[0] else { return .failed("The safety checker flagged the result.") }
                refined.append((rect, image))
            }
            guard let output = SceneRefinementCompositor.compose(scene: raster, tiles: refined, cover: cover,
                                                                 detail: settings.detail, feather: settings.feather)?.image else {
                return .failed("The refined tiles couldn’t be combined.")
            }
            return .refined(output)
        } catch {
            // A failed load or prediction can leave models half loaded.
            unload()
            return .failed("Stable Diffusion couldn’t run: \(error.localizedDescription)")
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

/// Plain color names for a cover's most prominent colors, used in the prompt so the
/// model paints in the artwork's palette.
enum SceneColorWords {
    static func describe(_ scene: ScenePixels, cover: CGRect, limit: Int = 3) -> [String] {
        let x0 = max(0, Int(cover.minX)), y0 = max(0, Int(cover.minY))
        let x1 = min(scene.width, Int(cover.maxX)), y1 = min(scene.height, Int(cover.maxY))
        guard x1 - x0 >= 8, y1 - y0 >= 8 else { return [] }
        var counts: [String: Double] = [:]
        var order: [String] = []
        let grid = 8
        for gy in 0..<grid { for gx in 0..<grid {
            // Average each grid cell, then name it.
            let cx0 = x0 + (x1 - x0) * gx / grid, cx1 = x0 + (x1 - x0) * (gx + 1) / grid
            let cy0 = y0 + (y1 - y0) * gy / grid, cy1 = y0 + (y1 - y0) * (gy + 1) / grid
            var r = 0.0, g = 0.0, b = 0.0, n = 0.0
            for y in stride(from: cy0, to: cy1, by: 2) { for x in stride(from: cx0, to: cx1, by: 2) {
                let i = (y * scene.width + x) * 4
                r += Double(scene.bytes[i]); g += Double(scene.bytes[i + 1]); b += Double(scene.bytes[i + 2]); n += 1
            } }
            guard n > 0 else { continue }
            let (name, weight) = Self.name(r: r / n / 255, g: g / n / 255, b: b / n / 255)
            if counts[name] == nil { order.append(name) }
            counts[name, default: 0] += weight
        } }
        return order.enumerated()
            .sorted { counts[$0.element]! != counts[$1.element]! ? counts[$0.element]! > counts[$1.element]! : $0.offset < $1.offset }
            .prefix(limit).map(\.element)
    }

    /// A color name and how much it should count (saturated colors characterize a cover more).
    static func name(r: Double, g: Double, b: Double) -> (String, Double) {
        let maxC = max(r, g, b), minC = min(r, g, b), delta = maxC - minC
        let brightness = maxC
        let saturation = maxC > 0 ? delta / maxC : 0
        if saturation < 0.18 || brightness < 0.08 {
            let name = brightness < 0.15 ? "black" : brightness < 0.45 ? "charcoal grey" : brightness < 0.8 ? "silver grey" : "white"
            return (name, 0.6)
        }
        var hue: Double
        if maxC == r { hue = 60 * ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
        else if maxC == g { hue = 60 * ((b - r) / delta + 2) }
        else { hue = 60 * ((r - g) / delta + 4) }
        if hue < 0 { hue += 360 }
        let base: String
        switch hue {
        case ..<15: base = "red"
        case ..<40: base = brightness < 0.55 ? "brown" : "orange"
        case ..<65: base = brightness < 0.55 ? "olive" : "gold"
        case ..<160: base = "green"
        case ..<190: base = "teal"
        case ..<250: base = "blue"
        case ..<285: base = "purple"
        case ..<330: base = "magenta"
        case ..<345: base = "crimson"
        default: base = "red"
        }
        let name = brightness < 0.35 ? "deep \(base)" : (brightness > 0.85 && saturation < 0.45 ? "pale \(base)" : base)
        return (name, 1 + saturation)
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
    /// Blends a mirrored copy of the cover into the scene around it. Each pixel outside
    /// the cover takes the cover pixel reflected back and forth across the cover's edges,
    /// so the echo continues the cover's own imagery without a seam where it meets the
    /// cover. The echo weakens a little with distance. The cover itself is unchanged.
    static func echoCover(scene: ScenePixels, cover: CGRect, amount: Double) -> ScenePixels {
        let cx = Int(cover.minX), cy = Int(cover.minY), cw = Int(cover.width), ch = Int(cover.height)
        guard cw > 1, ch > 1, cx >= 0, cy >= 0, cx + cw <= scene.width, cy + ch <= scene.height,
              amount > 0 else { return scene }
        func reflect(_ value: Int, _ start: Int, _ length: Int) -> Int {
            let period = 2 * length
            var t = (value - start) % period
            if t < 0 { t += period }
            return start + (t < length ? t : period - 1 - t)
        }
        var output = scene
        let width = scene.width, height = scene.height
        let fadeSpan = Double(max(width, height)) * 0.6
        let strength = amount.clamped(0, 1)
        for y in 0..<height {
            let sy = reflect(y, cy, ch)
            let dy = max(cy - y, y - (cy + ch - 1), 0)
            for x in 0..<width {
                let dx = max(cx - x, x - (cx + cw - 1), 0)
                guard dx > 0 || dy > 0 else { continue }
                let distance = Double(dx * dx + dy * dy).squareRoot()
                let weight = strength * (1 - 0.4 * min(1, distance / fadeSpan))
                let si = (sy * width + reflect(x, cx, cw)) * 4, oi = (y * width + x) * 4
                for c in 0..<3 {
                    let mixed = Double(scene.bytes[oi + c]) * (1 - weight) + Double(scene.bytes[si + c]) * weight
                    output.bytes[oi + c] = UInt8(mixed.rounded().clamped(0, 255))
                }
            }
        }
        return output
    }

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
