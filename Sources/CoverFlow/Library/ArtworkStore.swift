import AppKit
import ImageIO
import UniformTypeIdentifiers

struct SavedArtwork {
    var file: String
    var pixelWidth: Int
    var pixelHeight: Int
    var tintHex: String?
}

enum ArtworkError: LocalizedError {
    case notAnImage
    var errorDescription: String? { "That file isn’t an image Cover Flow can read." }
}

/// Stores original artwork on disk, serves downsampled thumbnails from a memory cache,
/// and full-resolution images for Album View.
final class ArtworkStore: @unchecked Sendable {
    let directory: URL
    private let cache = NSCache<NSString, NSImage>()
    private let fullCache = NSCache<NSString, NSImage>()

    init(directory: URL) {
        self.directory = directory
        cache.totalCostLimit = 320 * 1024 * 1024
        fullCache.countLimit = 3
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
        // Remove older versions for this album.
        if let existing = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
            for f in existing where f.hasPrefix(albumID.uuidString) {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(f))
            }
        }
        let name = "\(albumID.uuidString)-\(Int(Date().timeIntervalSince1970)).\(ext)"
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        let tint = Self.averageColor(source: src)?.hexString
        return SavedArtwork(file: name, pixelWidth: w, pixelHeight: h, tintHex: tint)
    }

    func remove(file: String?) {
        guard let file else { return }
        try? FileManager.default.removeItem(at: fileURL(file))
    }

    // MARK: Thumbnails

    static func bucket(for pixels: CGFloat) -> Int {
        if pixels <= 160 { return 160 }
        if pixels <= 360 { return 360 }
        if pixels <= 720 { return 720 }
        return 1100
    }

    func cachedThumbnail(_ album: Album, pixels: CGFloat) -> NSImage? {
        guard album.hasArtwork else { return nil }
        return cache.object(forKey: "\(album.artworkKey)@\(Self.bucket(for: pixels))" as NSString)
    }

    func thumbnail(_ album: Album, pixels: CGFloat) async -> NSImage? {
        guard let file = album.artworkFile else { return nil }
        let bucket = Self.bucket(for: pixels)
        let key = "\(album.artworkKey)@\(bucket)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let url = fileURL(file)
        let image: NSImage? = await Task.detached(priority: .userInitiated) {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: bucket
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
        if let image {
            let cost = Int(image.size.width * image.size.height * 4)
            cache.setObject(image, forKey: key, cost: cost)
        }
        return image
    }

    /// The original, full-resolution artwork — used by Album View so large covers stay sharp.
    func fullImage(_ album: Album) async -> NSImage? {
        guard let file = album.artworkFile else { return nil }
        let key = album.artworkKey as NSString
        if let hit = fullCache.object(forKey: key) { return hit }
        let url = fileURL(file)
        let image: NSImage? = await Task.detached(priority: .userInitiated) {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            // Decode with orientation applied, capped at a generous size.
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: 4096
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
        if let image { fullCache.setObject(image, forKey: key) }
        return image
    }

    func cachedFull(_ album: Album) -> NSImage? {
        guard album.hasArtwork else { return nil }
        return fullCache.object(forKey: album.artworkKey as NSString)
    }

    // MARK: Colour

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
