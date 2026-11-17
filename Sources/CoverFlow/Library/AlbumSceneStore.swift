import AppKit
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Generated scenes are versioned with the original cover and saved as still PNGs.
/// Color changes reuse the source scene; a new cover or variation gets a fresh scene.
actor AlbumSceneStore {
    private let artworkDirectory: URL
    private let directory: URL
    private var images: [String: CGImage] = [:]
    /// Least recently used first.
    private var recent: [String] = []
    /// In-flight work. Quilted generation reports `.failed` only when the cover can't be read.
    private var pending: [String: Task<SceneRefinementOutcome, Never>] = [:]
    /// Why a refinement failed or was flagged this session, so it isn't retried on every
    /// open and the Colors & Scene sheet can say what happened.
    private var failedRefinements: [String: String] = [:]

    init(artworkDirectory: URL) {
        self.artworkDirectory = artworkDirectory
        directory = artworkDirectory.appendingPathComponent("Scenes", isDirectory: true)
    }

    /// Marks refined scene files; quilted scene names never contain it.
    static let refinedMarker = "-sd2-"

    static func key(for album: Album, variation: Int, refinement: SceneRefinementStyle? = nil) -> String {
        "\(album.artworkKey)-scene-v5-\(variation)" + (refinement.map { refinedMarker + $0.rawValue } ?? "")
    }

    /// Why the requested refinement isn't showing, or nil when it succeeded or wasn't requested.
    func refinementFailure(for album: Album, variation: Int, refinement: SceneRefinementStyle?) -> String? {
        guard let refinement, album.artworkFile != nil else { return nil }
        guard AlbumSceneRefiner.isAvailable else { return AlbumSceneRefiner.unavailableReason }
        return failedRefinements[Self.key(for: album, variation: variation, refinement: refinement)]
    }

    /// The quilted scene, or with `refinement` its Stable Diffusion refinement when the
    /// model is available. A failed refinement falls back to the quilted scene.
    func scene(for album: Album, variation: Int, refinement requested: SceneRefinementStyle? = nil) async -> CGImage? {
        guard let file = album.artworkFile else { return nil }
        let refinement = AlbumSceneRefiner.isAvailable ? requested : nil
        let key = Self.key(for: album, variation: variation, refinement: refinement)
        if let image = images[key] { remember(image, key: key); return image }
        if let task = pending[key] {
            if case .refined(let image) = await task.value { return image }
            return refinement != nil ? await scene(for: album, variation: variation) : nil
        }
        let destination = directory.appendingPathComponent(key + ".png")
        if let source = CGImageSourceCreateWithURL(destination as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            remember(image, key: key)
            return image
        }
        let sourceURL = artworkDirectory.appendingPathComponent(file)
        let work: Task<SceneRefinementOutcome, Never>
        if let refinement {
            if failedRefinements[key] != nil { return await scene(for: album, variation: variation) }
            // Refinement starts from the quilted scene of the same variation.
            guard let base = await scene(for: album, variation: variation) else { return nil }
            // Another caller may have started this refinement while we waited.
            if let task = pending[key] {
                if case .refined(let image) = await task.value { return image }
                return await scene(for: album, variation: variation)
            }
            work = Task.detached(priority: .userInitiated) { () -> SceneRefinementOutcome in
                guard let cover = Self.thumbnail(sourceURL) else { return .failed("The cover couldn’t be read.") }
                let rect = AlbumSceneGenerator.coverRect(imageWidth: cover.width, imageHeight: cover.height,
                                                         size: CGSize(width: base.width, height: base.height))
                return await AlbumSceneRefiner.shared.refine(base, cover: rect, seed: key.stableHash, style: refinement)
            }
        } else {
            work = Task.detached(priority: .userInitiated) { () -> SceneRefinementOutcome in
                guard let image = Self.thumbnail(sourceURL),
                      let scene = AlbumSceneGenerator.generate(from: image, seed: key.stableHash) else {
                    return .failed("The cover couldn’t be used for a scene.")
                }
                return .refined(scene)
            }
        }
        pending[key] = work
        let outcome = await work.value
        pending[key] = nil
        guard !work.isCancelled else { return nil }
        let image: CGImage
        switch outcome {
        case .refined(let result):
            image = result
        case .failed(let reason):
            guard refinement != nil else { return nil }
            failedRefinements[key] = reason
            return await scene(for: album, variation: variation)
        }
        remember(image, key: key)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = NSMutableData()
        if let writer = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(writer, image, nil)
            if CGImageDestinationFinalize(writer) {
                try? (data as Data).write(to: destination, options: .atomic)
            }
        }
        // Keep one quilted and one refined disk scene per album rather than
        // accumulating every regeneration. Refined scenes are slow to make, so
        // switching refinement off and on again doesn't discard them.
        let siblings = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for old in siblings where old.lastPathComponent.hasPrefix(album.id.uuidString + "-") && old != destination
            && !old.lastPathComponent.contains("-immersive-")
            && old.lastPathComponent.contains(Self.refinedMarker) == (refinement != nil) {
            try? FileManager.default.removeItem(at: old)
        }
        return image
    }

    static func immersiveKey(for album: Album, layout: ImmersiveSceneLayout) -> String {
        let style = album.panelAppearance.immersiveRequestedRefinement?.rawValue ?? "base"
        return "\(album.artworkKey)-immersive-v3-\(style)-\(layout.key)-\(album.panelAppearance.immersiveKey.stableHash)"
    }

    func immersiveScene(for album: Album, layout: ImmersiveSceneLayout) async -> CGImage? {
        guard let file = album.artworkFile else { return nil }
        let settings = album.panelAppearance
        let key = Self.immersiveKey(for: album, layout: layout)
        if let image = images[key] { remember(image, key: key); return image }
        if let work = pending[key], case .refined(let image) = await work.value { return image }
        let destination = directory.appendingPathComponent(key + ".png")
        if let source = CGImageSourceCreateWithURL(destination as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            remember(image, key: key); return image
        }
        let sourceURL = artworkDirectory.appendingPathComponent(file)
        let work = Task.detached(priority: .userInitiated) { () -> SceneRefinementOutcome in
            guard let cover = Self.thumbnail(sourceURL),
                  let base = AlbumSceneGenerator.generate(from: cover, seed: key.stableHash,
                    size: layout.size, coverFrame: layout.cover, extensionTexture: 0.28) else { return .failed("The artwork scene couldn’t be prepared.") }
            if !Task.isCancelled, let style = settings.immersiveRequestedRefinement, AlbumSceneRefiner.isAvailable {
                let result = await AlbumSceneRefiner.shared.refine(base, cover: layout.cover,
                    seed: key.stableHash, style: style)
                if case .refined = result { return result }
            }
            return .refined(base)
        }
        pending[key] = work
        let outcome = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        pending[key] = nil
        guard !Task.isCancelled, !work.isCancelled, case .refined(let image) = outcome else { return nil }
        remember(image, key: key)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let destinationImage = CGImageDestinationCreateWithURL(destination as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(destinationImage, image, nil); CGImageDestinationFinalize(destinationImage)
        }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        // Keep one layout per style, so switching styles reuses saved scenes
        // while resizing or replacing artwork cannot grow the cache indefinitely.
        let styleMarker = "-immersive-v3-" + (settings.immersiveRequestedRefinement?.rawValue ?? "base") + "-"
        for old in files where old.lastPathComponent.hasPrefix(album.id.uuidString + "-")
            && old.lastPathComponent.contains("-immersive-") && old.lastPathComponent != destination.lastPathComponent {
            let name = old.lastPathComponent
            if !name.hasPrefix(album.artworkKey + "-") || !name.contains("-immersive-v3-") || name.contains(styleMarker) {
                try? FileManager.default.removeItem(at: old)
            }
        }
        return image
    }

    private static func thumbnail(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1024
        ] as CFDictionary)
    }

    func remove(for albumID: UUID) {
        let prefix = albumID.uuidString + "-"
        images = images.filter { !$0.key.hasPrefix(prefix) }
        recent.removeAll { $0.hasPrefix(prefix) }
        failedRefinements = failedRefinements.filter { !$0.key.hasPrefix(prefix) }
        for key in pending.keys.filter({ $0.hasPrefix(prefix) }) { pending.removeValue(forKey: key)?.cancel() }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix(prefix) { try? FileManager.default.removeItem(at: file) }
    }

    private func remember(_ image: CGImage, key: String) {
        images[key] = image
        recent.removeAll { $0 == key }
        recent.append(key)
        // Evict only the oldest scene instead of dropping the whole cache.
        while recent.count > 4 { images[recent.removeFirst()] = nil }
    }
}


/// The scene remains visible, but each final pixel must retain readable contrast
/// against every panel ink color. This also protects custom text/accent choices.
enum AlbumSceneRenderer {
    /// `emphasis` above 1 lets more of the scene show (used for ornate refinements);
    /// the per-pixel contrast check below still keeps every ink color readable.
    static func render(_ image: CGImage, colors: AlbumDetailPalette, strength: Double,
                       emphasis: Double = 1) -> CGImage? {
        guard var raster = ScenePixels(image: image, width: image.width, height: image.height) else { return nil }
        let inks = [colors.foreground.luminance, colors.secondary.luminance, colors.accent.luminance]
        func safe(_ color: AlbumDetailPalette.RGB) -> Bool {
            let luminance = color.luminance
            return inks.allSatisfy { (max($0, luminance) + 0.05) / (min($0, luminance) + 0.05) >= 4.5 }
        }
        let width = raster.width, height = raster.height
        let background = colors.background, clampedStrength = strength.clamped(0, 1)
        raster.bytes.withUnsafeMutableBufferPointer { buffer in
            guard let pixels = buffer.baseAddress else { return }
            // Every pixel is independent, so rows render on all cores.
            DispatchQueue.concurrentPerform(iterations: height) { y in
                let headerFade = ((Double(y) / Double(height) - 0.12) / 0.2).clamped(0, 1)
                let header = 0.65 + 0.35 * headerFade * headerFade * (3 - 2 * headerFade)
                for x in 0..<width {
                    let index = (y * width + x) * 4
                    let source = AlbumDetailPalette.RGB(r: Double(pixels[index]) / 255,
                                                        g: Double(pixels[index + 1]) / 255,
                                                        b: Double(pixels[index + 2]) / 255)
                    let side = ((Double(x) / Double(width) - 0.52) / 0.3).clamped(0, 1)
                    let amount = min(1, clampedStrength * emphasis * (0.18 + 0.44 * side * side * (3 - 2 * side)) * header)
                    func mixed(_ alpha: Double) -> AlbumDetailPalette.RGB {
                        let value = background.mixed(with: source, amount: alpha)
                        // Check the quantized color that will actually be written to the image.
                        return .init(r: (value.r * 255).rounded() / 255,
                                     g: (value.g * 255).rounded() / 255,
                                     b: (value.b * 255).rounded() / 255)
                    }
                    var result = mixed(amount)
                    if !safe(result) {
                        var low = 0.0, high = amount
                        for _ in 0..<10 {
                            let mid = (low + high) / 2
                            if safe(mixed(mid)) { low = mid } else { high = mid }
                        }
                        result = mixed(low)
                    }
                    pixels[index] = UInt8((result.r * 255).rounded().clamped(0, 255))
                    pixels[index + 1] = UInt8((result.g * 255).rounded().clamped(0, 255))
                    pixels[index + 2] = UInt8((result.b * 255).rounded().clamped(0, 255))
                    pixels[index + 3] = 255
                }
            }
        }
        return raster.image
    }
}
