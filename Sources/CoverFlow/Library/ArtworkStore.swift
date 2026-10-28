import AppKit
import ImageIO
import UniformTypeIdentifiers

struct SavedArtwork {
    var file: String
    var pixelWidth: Int
    var pixelHeight: Int
    var tintHex: String?
}

struct AlbumPanelStyle: @unchecked Sendable {
    let colors: AlbumDetailPalette
    let scene: CGImage?
    /// Why a requested Stable Diffusion refinement isn't showing; nil when it is (or wasn't requested).
    var refinementNote: String? = nil
}

enum ArtworkError: LocalizedError {
    case notAnImage
    var errorDescription: String? { "That file isn’t an image Cover Flow can read." }
}

/// Stores original artwork on disk, serves downsampled thumbnails from a memory cache,
/// and full-resolution images for Album View.
final class ArtworkStore: @unchecked Sendable {
    let directory: URL
    let scenes: AlbumSceneStore
    private let rasters: ArtworkRasterCache
    private let decoder: ArtworkDecoder
    private final class PaletteBox {
        let colors: AlbumDetailPalette
        init(_ colors: AlbumDetailPalette) { self.colors = colors }
    }
    private let detailPaletteCache = NSCache<NSString, PaletteBox>()
    private final class PanelStyleBox {
        let style: AlbumPanelStyle
        init(_ style: AlbumPanelStyle) { self.style = style }
    }
    private let panelStyleCache = NSCache<NSString, PanelStyleBox>()

    init(directory: URL) {
        self.directory = directory
        scenes = AlbumSceneStore(artworkDirectory: directory)
        let rasters = ArtworkRasterCache()
        self.rasters = rasters; decoder = ArtworkDecoder(cache: rasters)
        detailPaletteCache.countLimit = 512
        panelStyleCache.totalCostLimit = 32 * 1024 * 1024
    }

    func fileURL(_ file: String) -> URL { directory.appendingPathComponent(file) }

    /// Writes original artwork bytes. Safe to call off the main thread.
    func save(data: Data, albumID: UUID) throws -> SavedArtwork {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(src) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
            throw ArtworkError.notAnImage
        }
        var w = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0
        var h = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
        if let orientation = props[kCGImagePropertyOrientation] as? Int, orientation >= 5 { swap(&w, &h) }
        guard w > 0, h > 0 else { throw ArtworkError.notAnImage }

        let type = (CGImageSourceGetType(src) as String?).flatMap { UTType($0) }
        let ext = type?.preferredFilenameExtension ?? "img"
        let name = "\(albumID.uuidString)-\(UUID().uuidString).\(ext)"
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        // Only remove older versions after the new image is safely stored.
        if let existing = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
            for f in existing where f.hasPrefix(albumID.uuidString) && f != name {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(f))
            }
        }
        let tint = Self.averageColor(source: src)?.hexString
        return SavedArtwork(file: name, pixelWidth: w, pixelHeight: h, tintHex: tint)
    }

    func remove(file: String?) {
        guard let file else { return }
        try? FileManager.default.removeItem(at: fileURL(file))
        if let id = UUID(uuidString: String(file.prefix(36))) { Task { await scenes.remove(for: id) } }
    }

    // MARK: Thumbnails

    static func bucket(for pixels: CGFloat) -> Int {
        if pixels <= 160 { return 160 }
        if pixels <= 360 { return 360 }
        if pixels <= 720 { return 720 }
        return 1100
    }

    @MainActor
    func cachedThumbnail(_ album: Album, pixels: CGFloat) -> NSImage? {
        guard let file = album.artworkFile,
              let cached = rasters.value(for: fileURL(file), pixels: Self.bucket(for: pixels)) else { return nil }
        return Self.appKitImage(cached)
    }

    @MainActor
    func thumbnail(_ album: Album, pixels: CGFloat) async -> NSImage? {
        await image(album, pixels: Self.bucket(for: pixels))
    }

    /// Orientation-aware full artwork, bounded to 4096 pixels and a separate
    /// raster budget so large covers cannot evict every browsing thumbnail.
    @MainActor
    func fullImage(_ album: Album) async -> NSImage? { await image(album, pixels: 4096) }

    @MainActor
    func cachedFull(_ album: Album) -> NSImage? {
        guard let file = album.artworkFile,
              let cached = rasters.value(for: fileURL(file), pixels: 4096) else { return nil }
        return Self.appKitImage(cached)
    }

    @MainActor
    private func image(_ album: Album, pixels: Int) async -> NSImage? {
        guard let file = album.artworkFile, !Task.isCancelled,
              let result = await decoder.image(at: fileURL(file), pixels: pixels),
              !Task.isCancelled else { return nil }
        return Self.appKitImage(result)
    }

    @MainActor
    private static func appKitImage(_ artwork: DecodedArtwork) -> NSImage {
        let cg = artwork.image
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    // MARK: Colour

    @MainActor
    func albumPanelStyle(_ album: Album, appearance: AlbumAppearance? = nil) async -> AlbumPanelStyle {
        let settings = appearance ?? album.panelAppearance
        let metadata = album.hasArtwork ? "" : "\(album.title)|\(album.artist)|\(album.tintHex ?? "")"
        let key = "\(album.artworkKey)|\(metadata)|\(settings.key)" as NSString
        if let hit = panelStyleCache.object(forKey: key) { return hit.style }
        let automatic = await albumDetailPalette(album)
        let colors = automatic.customized(settings)
        var scene: CGImage?
        var note: String?
        if settings.sceneEnabled, settings.strength > 0,
           let source = await scenes.scene(for: album, variation: settings.sceneVariation,
                                          refinement: settings.requestedRefinement) {
            note = await scenes.refinementFailure(for: album, variation: settings.sceneVariation,
                                                  refinement: settings.requestedRefinement)
            // A successful refinement may be shown more strongly so its detail reads.
            let emphasis = note == nil ? settings.requestedRefinement?.emphasis ?? 1 : 1
            scene = await Task.detached(priority: .userInitiated) {
                AlbumSceneRenderer.render(source, colors: colors, strength: settings.strength, emphasis: emphasis)
            }.value
        }
        let style = AlbumPanelStyle(colors: colors, scene: scene, refinementNote: note)
        panelStyleCache.setObject(PanelStyleBox(style), forKey: key,
                                  cost: (scene?.width ?? 0) * (scene?.height ?? 0) * 4 + 128)
        return style
    }

    /// Prepare the palette and cover before presenting album tracks. The cache is
    /// versioned with the artwork so replacing a cover naturally gets fresh colors.
    @MainActor
    func albumDetailPalette(_ album: Album) async -> AlbumDetailPalette {
        let key = album.artworkKey as NSString
        if let hit = detailPaletteCache.object(forKey: key) { return hit.colors }
        guard let image = await thumbnail(album, pixels: 720),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return AlbumDetailPalette.fallback(album)
        }
        let colors = await Task.detached(priority: .userInitiated) { AlbumDetailPalette.extract(from: cg) }.value
        guard let colors else { return AlbumDetailPalette.fallback(album) }
        detailPaletteCache.setObject(PaletteBox(colors), forKey: key)
        return colors
    }

    static func averageColor(source: CGImageSource) -> NSColor? {
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 48
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else { return nil }
        let n = 12
        var pixels = [UInt8](repeating: 0, count: n * n * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ok: Bool = pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard ok else { return nil }
        var r = 0.0, g = 0.0, b = 0.0, weight = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let pr = Double(pixels[i]) / 255, pg = Double(pixels[i + 1]) / 255, pb = Double(pixels[i + 2]) / 255
            // Favour saturated pixels a little so the tint carries the cover's character, not just grey.
            let sat = max(pr, pg, pb) - min(pr, pg, pb)
            let w = 0.35 + sat
            r += pr * w; g += pg * w; b += pb * w; weight += w
        }
        guard weight > 0 else { return nil }
        return NSColor(srgbRed: r / weight, green: g / weight, blue: b / weight, alpha: 1)
    }
}
