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
        "\(album.artworkKey)-scene-v4-\(variation)"
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
        if images.count >= 4 { images.removeAll(keepingCapacity: true) }
        images[key] = image
    }
}

/// Exemplar-based image extension: preserve cover content on the artwork side,
/// then grow its surrounding texture with patches matched to existing neighbors.
/// Text, face, and salient subject regions are excluded from patch sampling so titles are not tiled behind tracks.
enum AlbumSceneGenerator {
    static let canvasSize = CGSize(width: 2160, height: 1320)

    static func generate(from image: CGImage, seed: UInt64, analyzeText: Bool = true,
                         size: CGSize = canvasSize) -> CGImage? {
        guard size.width.isFinite, size.height.isFinite,
              size.width >= 128, size.height >= 128,
              size.width <= 2160, size.height <= 1320 else { return nil }
        let width = Int(size.width), height = Int(size.height)
        let sourceLimit = min(768, Double(width) * 0.36, Double(height) * 0.6)
        let scale = min(1, sourceLimit / Double(max(image.width, image.height)))
        let sw = max(32, Int(Double(image.width) * scale))
        let sh = max(32, Int(Double(image.height) * scale))
        guard var source = ScenePixels(image: image, width: sw, height: sh) else { return nil }
        let patch = min(128, max(16, min(sw, sh) / 3)), overlap = max(4, patch / 3)
        let step = patch - overlap
        let anchorX = min(width - sw - 12, Int(Double(width) * 0.77) - sw / 2)
        let anchorY = (height - sh) / 2
        var known = [Bool](repeating: false, count: width * height)
        var locked = known
        let textBoxes: [CGRect]
        let subjectBoxes: [CGRect]
        if analyzeText {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            let faces = VNDetectFaceRectanglesRequest()
            let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
            try? VNImageRequestHandler(cgImage: image).perform([request, faces, saliency])
            textBoxes = (request.results ?? []).map { observation in
                let box = observation.boundingBox
                return CGRect(x: box.minX * Double(sw), y: (1 - box.maxY) * Double(sh),
                              width: box.width * Double(sw), height: box.height * Double(sh)).insetBy(dx: -3, dy: -3)
            }
            let subjects: [VNDetectedObjectObservation] = (faces.results ?? []) + (saliency.results?.first?.salientObjects ?? [])
            subjectBoxes = subjects.map { observation in
                let box = observation.boundingBox
                return CGRect(x: box.minX * Double(sw), y: (1 - box.maxY) * Double(sh),
                              width: box.width * Double(sw), height: box.height * Double(sh)).insetBy(dx: -8, dy: -8)
            }
        } else { textBoxes = []; subjectBoxes = [] }
        source.clearLettering(in: textBoxes)
        // Separate broad cover colors from fine texture. Extending the smooth
        // edge colors prevents every pasted patch from becoming a different block.
        guard let sourceImage = source.image,
              let small = ScenePixels(image: sourceImage, width: min(48, sw), height: min(48, sh)),
              let smallImage = small.image,
              let low = ScenePixels(image: smallImage, width: sw, height: sh) else { return nil }
        var field = ScenePixels(width: width, height: height)
        for y in 0..<height { for x in 0..<width {
            let sx = (x - anchorX).clamped(0, sw - 1)
            let sy = (y - anchorY).clamped(0, sh - 1)
            field.copyPixel(y * width + x, from: low, index: sy * sw + sx)
        } }
        var output = field
        for y in 0..<sh { for x in 0..<sw {
            let target = (anchorY + y) * width + anchorX + x
            output.copyPixel(target, from: source, index: y * sw + x)
            known[target] = true; locked[target] = true
        } }
        struct Patch { let x: Int; let y: Int; let variation: Double }
        var candidates: [Patch] = []
        for sy in stride(from: 0, through: sh - patch, by: max(6, patch / 4)) {
            for sx in stride(from: 0, through: sw - patch, by: max(6, patch / 4)) {
                let rect = CGRect(x: sx, y: sy, width: patch, height: patch)
                guard !(textBoxes + subjectBoxes).contains(where: { $0.intersects(rect) }) else { continue }
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
        if candidates.isEmpty {
            // Text/portraits covering the whole image leave no safe exemplars.
            // Use a smooth cover-colored field rather than tile a face or title.
            guard let clean = source.image,
                  let small = ScenePixels(image: clean, width: 8, height: 8),
                  let smallImage = small.image,
                  let field = ScenePixels(image: smallImage, width: width, height: height) else { return nil }
            return field.image
        }
        // Strong object edges can match a neighboring edge perfectly and then
        // repeat fragments of the subject. Restrict extension to quieter exemplars.
        candidates.sort {
            if $0.variation != $1.variation { return $0.variation < $1.variation }
            if $0.y != $1.y { return $0.y < $1.y }
            return $0.x < $1.x
        }
        candidates = Array(candidates.prefix(max(1, Int(Double(candidates.count) * 0.65))))
        var uses = [Int](repeating: 0, count: candidates.count)
        var random = seed
        func next(_ upper: Int) -> Int {
            random = random &* 6364136223846793005 &+ 1442695040888963407
            return Int((random >> 32) % UInt64(upper))
        }
        // Visit patches touching the preserved cover first, then grow outwards.
        // A simple raster scan would seed disconnected rows with unrelated textures.
        var placements: [(x: Int, y: Int, distance: Int)] = []
        for px in stride(from: width - patch, through: -step, by: -step) {
            for py in stride(from: 0, to: height, by: step) {
                let tx = max(0, px), ty = min(py, height - patch)
                let dx = max(anchorX - (tx + patch), tx - (anchorX + sw), 0)
                let dy = max(anchorY - (ty + patch), ty - (anchorY + sh), 0)
                placements.append((tx, ty, dx + dy))
            }
        }
        placements.sort {
            if $0.distance != $1.distance { return $0.distance < $1.distance }
            if $0.x != $1.x { return $0.x > $1.x }
            return $0.y < $1.y
        }
        for placement in placements {
            if Task.isCancelled { return nil }
            let tx = placement.x, ty = placement.y
            if tx >= anchorX && ty >= anchorY && tx + patch <= anchorX + sw && ty + patch <= anchorY + sh { continue }
            var bestIndex = next(candidates.count), bestError = Double.infinity
            for _ in 0..<80 {
                let candidateIndex = next(candidates.count)
                let candidate = candidates[candidateIndex]
                var error = 0.0, samples = 0
                for y in stride(from: 0, to: patch, by: max(4, patch / 12)) {
                    for x in stride(from: 0, to: patch, by: max(4, patch / 12)) {
                        let index = (ty + y) * width + tx + x
                        guard known[index] else { continue }
                        for c in 0..<3 {
                            let si = ((candidate.y + y) * sw + candidate.x + x) * 4 + c
                            let existing = Double(output.bytes[index * 4 + c]) - Double(field.bytes[index * 4 + c])
                            let texture = Double(source.bytes[si]) - Double(low.bytes[si])
                            let d = existing - texture
                            error += d * d
                        }
                        samples += 1
                    }
                }
                error = error / Double(max(1, samples)) + candidate.variation * (tx < width * 2 / 3 ? 1.4 : 0.3)
                error += Double(uses[candidateIndex]) * 24
                if error < bestError { bestIndex = candidateIndex; bestError = error }
            }
            let best = candidates[bestIndex]
            uses[bestIndex] += 1
            var proposed = ScenePixels(width: patch, height: patch)
            for y in 0..<patch { for x in 0..<patch {
                let oi = ((ty + y) * width + tx + x) * 4
                let si = ((best.y + y) * sw + best.x + x) * 4
                let pi = (y * patch + x) * 4
                for c in 0..<3 {
                    let texture = Double(source.bytes[si + c]) - Double(low.bytes[si + c])
                    proposed.bytes[pi + c] = UInt8((Double(field.bytes[oi + c]) + texture * 0.75).rounded().clamped(0, 255))
                }
            } }
            let weights = SceneQuilting.weights(output: output, source: proposed, known: known,
                targetX: tx, targetY: ty, sourceX: 0, sourceY: 0,
                patch: patch, overlap: overlap)
            for y in 0..<patch { for x in 0..<patch {
                let index = (ty + y) * width + tx + x
                guard !locked[index] else { continue }
                let si = (y * patch + x) * 4
                let amount = known[index] ? weights[y * patch + x] : 1
                for c in 0..<3 {
                    output.bytes[index * 4 + c] = UInt8((Double(output.bytes[index * 4 + c]) * (1 - amount)
                        + Double(proposed.bytes[si + c]) * amount).rounded())
                }
                output.bytes[index * 4 + 3] = 255
                known[index] = true
            } }
        }
        return output.image
    }
}

/// Image quilting chooses a low-error path through an overlap instead of
/// averaging two whole patches (which doubles edges and erases fine texture).
enum SceneQuilting {
    static func minimumCut(costs: [Double], length: Int, depth: Int) -> [Int] {
        precondition(length > 0 && depth > 0 && costs.count == length * depth)
        var accumulated = costs
        var parents = [Int](repeating: 0, count: costs.count)
        if length > 1 {
            for row in 1..<length {
                for column in 0..<depth {
                    let previous = (row - 1) * depth
                    var best = column
                    for candidate in max(0, column - 1)...min(depth - 1, column + 1) {
                        if accumulated[previous + candidate] < accumulated[previous + best] { best = candidate }
                    }
                    accumulated[row * depth + column] += accumulated[previous + best]
                    parents[row * depth + column] = best
                }
            }
        }
        var cut = [Int](repeating: 0, count: length)
        let last = (length - 1) * depth
        cut[length - 1] = (0..<depth).min { accumulated[last + $0] < accumulated[last + $1] }!
        if length > 1 {
            for row in stride(from: length - 1, through: 1, by: -1) {
                cut[row - 1] = parents[row * depth + cut[row]]
            }
        }
        return cut
    }

    static func weights(output: ScenePixels, source: ScenePixels, known: [Bool],
                        targetX: Int, targetY: Int, sourceX: Int, sourceY: Int,
                        patch: Int, overlap: Int) -> [Double] {
        var weights = [Double](repeating: 1, count: patch * patch)
        // Handle all four directions because generation grows away from the cover.
        for edge in 0..<4 {
            func point(_ along: Int, _ inward: Int) -> (x: Int, y: Int) {
                switch edge {
                case 0: return (inward, along)
                case 1: return (patch - 1 - inward, along)
                case 2: return (along, inward)
                default: return (along, patch - 1 - inward)
                }
            }
            let existing = (0..<patch).filter { along in
                let p = point(along, 0)
                return known[(targetY + p.y) * output.width + targetX + p.x]
            }.count
            guard existing >= patch / 2 else { continue }
            var costs = [Double](repeating: 0, count: patch * overlap)
            for along in 0..<patch { for inward in 0..<overlap {
                let p = point(along, inward)
                let oi = (targetY + p.y) * output.width + targetX + p.x
                guard known[oi] else { continue }
                let si = ((sourceY + p.y) * source.width + sourceX + p.x) * 4
                for c in 0..<3 {
                    let delta = Double(output.bytes[oi * 4 + c]) - Double(source.bytes[si + c])
                    costs[along * overlap + inward] += delta * delta
                }
            } }
            let cut = minimumCut(costs: costs, length: patch, depth: overlap)
            for along in 0..<patch { for inward in 0..<overlap {
                let p = point(along, inward)
                // Feather just three pixels on either side of the cut.
                let alpha = (Double(inward - cut[along]) / 6 + 0.5).clamped(0, 1)
                weights[p.y * patch + p.x] = min(weights[p.y * patch + p.x], alpha)
            } }
        }
        return weights
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
            let headerFade = ((Double(y) / Double(raster.height) - 0.12) / 0.2).clamped(0, 1)
            let header = 0.65 + 0.35 * headerFade * headerFade * (3 - 2 * headerFade)
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
