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
    private var pending: [String: Task<CGImage?, Never>] = [:]

    init(artworkDirectory: URL) {
        self.artworkDirectory = artworkDirectory
        directory = artworkDirectory.appendingPathComponent("Scenes", isDirectory: true)
    }

    static func key(for album: Album, variation: Int) -> String {
        "\(album.artworkKey)-scene-v3-\(variation)"
    }

    func scene(for album: Album, variation: Int) async -> CGImage? {
        guard let file = album.artworkFile else { return nil }
        let key = Self.key(for: album, variation: variation)
        if let image = images[key] { return image }
        if let task = pending[key] { return await task.value }
        let destination = directory.appendingPathComponent(key + ".png")
        if let source = CGImageSourceCreateWithURL(destination as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            remember(image, key: key)
            return image
        }
        let sourceURL = artworkDirectory.appendingPathComponent(file)
        let work = Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1024
                  ] as CFDictionary) else { return nil }
            return AlbumSceneGenerator.generate(from: image, seed: key.stableHash)
        }
        pending[key] = work
        let image = await work.value
        pending[key] = nil
        guard !work.isCancelled else { return nil }
        guard let image else { return nil }
        remember(image, key: key)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = NSMutableData()
        if let writer = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(writer, image, nil)
            if CGImageDestinationFinalize(writer) {
                try? (data as Data).write(to: destination, options: .atomic)
            }
        }
        // Keep one disk scene per album rather than accumulating every regeneration.
        let siblings = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for old in siblings where old.lastPathComponent.hasPrefix(album.id.uuidString + "-") && old != destination {
            try? FileManager.default.removeItem(at: old)
        }
        return image
    }

    func remove(for albumID: UUID) {
        let prefix = albumID.uuidString + "-"
        images = images.filter { !$0.key.hasPrefix(prefix) }
        for key in pending.keys.filter({ $0.hasPrefix(prefix) }) { pending.removeValue(forKey: key)?.cancel() }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix(prefix) { try? FileManager.default.removeItem(at: file) }
    }

    private func remember(_ image: CGImage, key: String) {
        if images.count >= 24 { images.removeAll(keepingCapacity: true) }
        images[key] = image
    }
}

/// Exemplar-based image extension: preserve cover content on the artwork side,
/// then grow its surrounding texture with patches matched to existing neighbors.
/// Text regions are excluded from patch sampling so titles are not tiled behind tracks.
enum AlbumSceneGenerator {
    static func generate(from image: CGImage, seed: UInt64, analyzeText: Bool = true) -> CGImage? {
        let scale = min(1, 192.0 / Double(max(image.width, image.height)))
        let sw = max(32, Int(Double(image.width) * scale))
        let sh = max(32, Int(Double(image.height) * scale))
        guard var source = ScenePixels(image: image, width: sw, height: sh) else { return nil }
        let width = 480, height = 300, patch = min(32, min(sw, sh)), step = max(8, patch - 8)
        let anchorX = min(width - sw - 12, Int(Double(width) * 0.77) - sw / 2)
        let anchorY = (height - sh) / 2
        var output = ScenePixels(width: width, height: height)
        var known = [Bool](repeating: false, count: width * height)
        var locked = known
        let textBoxes: [CGRect]
        if analyzeText {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            try? VNImageRequestHandler(cgImage: image).perform([request])
            textBoxes = (request.results ?? []).map { observation in
                let box = observation.boundingBox
                return CGRect(x: box.minX * Double(sw), y: (1 - box.maxY) * Double(sh),
                              width: box.width * Double(sw), height: box.height * Double(sh)).insetBy(dx: -3, dy: -3)
            }
        } else { textBoxes = [] }
        source.clearLettering(in: textBoxes)
        for y in 0..<sh { for x in 0..<sw {
            let target = (anchorY + y) * width + anchorX + x
            output.copyPixel(target, from: source, index: y * sw + x)
            known[target] = true; locked[target] = true
        } }
        struct Patch { let x: Int; let y: Int; let variation: Double }
        var candidates: [Patch] = []
        for sy in stride(from: 0, through: sh - patch, by: 6) {
            for sx in stride(from: 0, through: sw - patch, by: 6) {
                let rect = CGRect(x: sx, y: sy, width: patch, height: patch)
                guard !textBoxes.contains(where: { $0.intersects(rect) }) else { continue }
                // Favor quiet cover regions rather than repeatedly cloning central subjects.
                var gradient = 0.0
                for y in stride(from: 0, to: patch - 4, by: 4) {
                    for x in stride(from: 0, to: patch - 4, by: 4) {
                        for c in 0..<3 {
                            let p = Double(source.bytes[((sy + y) * sw + sx + x) * 4 + c])
                            let q = Double(source.bytes[((sy + y + 4) * sw + sx + x + 4) * 4 + c])
                            gradient += (p - q) * (p - q)
                        }
                    }
                }
                candidates.append(Patch(x: sx, y: sy, variation: gradient / Double(patch * patch)))
            }
        }
        if candidates.isEmpty { candidates = [Patch(x: 0, y: 0, variation: 0)] }
        var random = seed
        func next(_ upper: Int) -> Int {
            random = random &* 6364136223846793005 &+ 1442695040888963407
            return Int((random >> 32) % UInt64(upper))
        }
        // Grow from the artwork toward the text side; feather only synthetic overlaps.
        for px in stride(from: width - patch, through: -step, by: -step) {
            if Task.isCancelled { return nil }
            let tx = max(0, px)
            for py in stride(from: 0, to: height, by: step) {
                let ty = min(py, height - patch)
                var best = candidates[next(candidates.count)], bestError = Double.infinity
                for _ in 0..<48 {
                    let candidate = candidates[next(candidates.count)]
                    var error = 0.0, samples = 0
                    for y in stride(from: 0, to: patch, by: 4) {
                        for x in stride(from: 0, to: patch, by: 4) {
                            let index = (ty + y) * width + tx + x
                            guard known[index] else { continue }
                            for c in 0..<3 {
                                let d = Double(output.bytes[index * 4 + c]) - Double(source.bytes[((candidate.y + y) * sw + candidate.x + x) * 4 + c])
                                error += d * d
                            }
                            samples += 1
                        }
                    }
                    error = error / Double(max(1, samples)) + candidate.variation * (tx < width * 2 / 3 ? 1.4 : 0.3)
                    if error < bestError { best = candidate; bestError = error }
                }
                for y in 0..<patch { for x in 0..<patch {
                    let index = (ty + y) * width + tx + x
                    guard !locked[index] else { continue }
                    let si = ((best.y + y) * sw + best.x + x) * 4
                    for c in 0..<3 {
                        output.bytes[index * 4 + c] = known[index]
                            ? UInt8((Int(output.bytes[index * 4 + c]) + Int(source.bytes[si + c])) / 2)
                            : source.bytes[si + c]
                    }
                    output.bytes[index * 4 + 3] = 255
                    known[index] = true
                } }
            }
        }
        return output.image
    }
}

/// The scene remains visible, but each final pixel must retain readable contrast
/// against every panel ink color. This also protects custom text/accent choices.
enum AlbumSceneRenderer {
    static func render(_ image: CGImage, colors: AlbumDetailPalette, strength: Double) -> CGImage? {
        guard var raster = ScenePixels(image: image, width: image.width, height: image.height) else { return nil }
        let inks = [colors.foreground.luminance, colors.secondary.luminance, colors.accent.luminance]
        func safe(_ color: AlbumDetailPalette.RGB) -> Bool {
            let luminance = color.luminance
            return inks.allSatisfy { (max($0, luminance) + 0.05) / (min($0, luminance) + 0.05) >= 4.5 }
        }
        for y in 0..<raster.height { for x in 0..<raster.width {
            let index = (y * raster.width + x) * 4
            let source = AlbumDetailPalette.RGB(r: Double(raster.bytes[index]) / 255,
                                                g: Double(raster.bytes[index + 1]) / 255,
                                                b: Double(raster.bytes[index + 2]) / 255)
            let side = ((Double(x) / Double(raster.width) - 0.52) / 0.3).clamped(0, 1)
            let header = y < raster.height / 4 ? 0.65 : 1.0
            let amount = strength.clamped(0, 1) * (0.18 + 0.44 * side * side * (3 - 2 * side)) * header
            func mixed(_ alpha: Double) -> AlbumDetailPalette.RGB {
                let value = colors.background.mixed(with: source, amount: alpha)
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
            raster.bytes[index] = UInt8((result.r * 255).rounded().clamped(0, 255))
            raster.bytes[index + 1] = UInt8((result.g * 255).rounded().clamped(0, 255))
            raster.bytes[index + 2] = UInt8((result.b * 255).rounded().clamped(0, 255))
            raster.bytes[index + 3] = 255
        } }
        return raster.image
    }
}

struct ScenePixels {
    let width: Int
    let height: Int
    var bytes: [UInt8]

    init(width: Int, height: Int) {
        self.width = width; self.height = height
        bytes = [UInt8](repeating: 0, count: width * height * 4)
        for index in stride(from: 3, to: bytes.count, by: 4) { bytes[index] = 255 }
    }

    init?(image: CGImage, width: Int, height: Int) {
        self.init(width: width, height: height)
        let ok = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        if !ok { return nil }
    }

    mutating func copyPixel(_ index: Int, from source: ScenePixels, index sourceIndex: Int) {
        for c in 0..<4 { bytes[index * 4 + c] = source.bytes[sourceIndex * 4 + c] }
    }

    mutating func clearLettering(in rectangles: [CGRect]) {
        for rect in rectangles {
            let x0 = max(0, Int(rect.minX)), x1 = min(width - 1, Int(ceil(rect.maxX)))
            let y0 = max(0, Int(rect.minY)), y1 = min(height - 1, Int(ceil(rect.maxY)))
            guard x0 <= x1, y0 <= y1 else { continue }
            let above = max(0, y0 - 2), below = min(height - 1, y1 + 2)
            let original = bytes
            for y in y0...y1 {
                let fraction = Double(y - y0 + 1) / Double(y1 - y0 + 2)
                for x in x0...x1 {
                    for channel in 0..<3 {
                        let top = Double(original[(above * width + x) * 4 + channel])
                        let bottom = Double(original[(below * width + x) * 4 + channel])
                        bytes[(y * width + x) * 4 + channel] = UInt8((top * (1 - fraction) + bottom * fraction).rounded())
                    }
                }
            }
        }
    }

    var image: CGImage? {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
