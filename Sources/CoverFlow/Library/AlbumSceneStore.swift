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
            && old.lastPathComponent.contains(Self.refinedMarker) == (refinement != nil) {
            try? FileManager.default.removeItem(at: old)
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

/// Exemplar-based image extension: preserve cover content on the artwork side,
/// then grow its surrounding texture with patches matched to existing neighbors.
/// Text, face, and salient subject regions are excluded from patch sampling so titles are not tiled behind tracks.
enum AlbumSceneGenerator {
    static let canvasSize = CGSize(width: 2160, height: 1320)

    /// Where the preserved cover sits in a scene of `size` generated from an image
    /// of these dimensions, in pixels from the top-left.
    static func coverRect(imageWidth: Int, imageHeight: Int, size: CGSize = canvasSize) -> CGRect {
        let width = Int(size.width), height = Int(size.height)
        let sourceLimit = min(768, Double(width) * 0.36, Double(height) * 0.6)
        let scale = min(1, sourceLimit / Double(max(imageWidth, imageHeight)))
        let sw = max(32, Int(Double(imageWidth) * scale))
        let sh = max(32, Int(Double(imageHeight) * scale))
        let anchorX = min(width - sw - 12, Int(Double(width) * 0.77) - sw / 2)
        return CGRect(x: anchorX, y: (height - sh) / 2, width: sw, height: sh)
    }

    static func generate(from image: CGImage, seed: UInt64, analyzeText: Bool = true,
                         size: CGSize = canvasSize) -> CGImage? {
        guard size.width.isFinite, size.height.isFinite,
              size.width >= 128, size.height >= 128,
              size.width <= 2160, size.height <= 1320 else { return nil }
        let width = Int(size.width), height = Int(size.height)
        let layout = coverRect(imageWidth: image.width, imageHeight: image.height, size: size)
        let sw = Int(layout.width), sh = Int(layout.height)
        guard var source = ScenePixels(image: image, width: sw, height: sh) else { return nil }
        let patch = min(128, max(16, min(sw, sh) / 3)), overlap = max(4, patch / 3)
        let step = patch - overlap
        let anchorX = Int(layout.minX), anchorY = Int(layout.minY)
        var known = [Bool](repeating: false, count: width * height)
        var locked = known
        let textBoxes: [CGRect]
        let subjectBoxes: [CGRect]
        if analyzeText {
            let request = VNRecognizeTextRequest()
            // Only the boxes are used, never the words, so the fast recognizer is enough.
            request.recognitionLevel = .fast
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
        if Task.isCancelled { return nil }
        source.clearLettering(in: textBoxes)
        // Separate broad cover colors from fine texture. Extending the smooth
        // edge colors prevents every pasted patch from becoming a different block.
        guard let sourceImage = source.image,
              let small = ScenePixels(image: sourceImage, width: min(48, sw), height: min(48, sh)),
              let smallImage = small.image,
              let low = ScenePixels(image: smallImage, width: sw, height: sh) else { return nil }
        let field = SceneField.extend(low, width: width, height: height, anchorX: anchorX, anchorY: anchorY)
        if Task.isCancelled { return nil }
        // Texture is strongest beside the cover and calmer far behind the track list.
        func textureAmount(_ x: Int, _ y: Int) -> Double {
            let dx = max(anchorX - x, x - (anchorX + sw - 1), 0)
            let dy = max(anchorY - y, y - (anchorY + sh - 1), 0)
            let t = (Double(dx * dx + dy * dy).squareRoot() / (Double(width) * 0.6)).clamped(0, 1)
            return 0.75 * (1 - 0.45 * t * t * (3 - 2 * t))
        }
        var output = field
        for y in 0..<sh { for x in 0..<sw {
            let target = (anchorY + y) * width + anchorX + x
            output.copyPixel(target, from: source, index: y * sw + x)
            known[target] = true; locked[target] = true
        } }
        // Patches are never mirrored: a mirrored edge sliver of a subject matches the
        // cover's quiet border and then carries that subject away from the cover.
        struct Patch { let x: Int; let y: Int; let variation: Double }
        func sourceIndex(_ candidate: Patch, _ x: Int, _ y: Int) -> Int {
            (candidate.y + y) * sw + candidate.x + x
        }
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
        var seen = Set<Int>()
        for px in stride(from: width - patch, through: -step, by: -step) {
            for py in stride(from: 0, to: height, by: step) {
                let tx = max(0, px), ty = min(py, height - patch)
                // Clamping at the left and bottom edges can repeat a position.
                guard seen.insert(ty * width + tx).inserted else { continue }
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
            for _ in 0..<120 {
                let candidateIndex = next(candidates.count)
                let candidate = candidates[candidateIndex]
                var error = 0.0, samples = 0
                for y in stride(from: 0, to: patch, by: max(4, patch / 12)) {
                    for x in stride(from: 0, to: patch, by: max(4, patch / 12)) {
                        let index = (ty + y) * width + tx + x
                        guard known[index] else { continue }
                        let amount = textureAmount(tx + x, ty + y)
                        let base = sourceIndex(candidate, x, y) * 4
                        for c in 0..<3 {
                            let si = base + c
                            let existing = Double(output.bytes[index * 4 + c]) - Double(field.bytes[index * 4 + c])
                            let texture = (Double(source.bytes[si]) - Double(low.bytes[si])) * amount
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
                let si = sourceIndex(best, x, y) * 4
                let pi = (y * patch + x) * 4
                let amount = textureAmount(tx + x, ty + y)
                for c in 0..<3 {
                    let texture = Double(source.bytes[si + c]) - Double(low.bytes[si + c])
                    proposed.bytes[pi + c] = UInt8((Double(field.bytes[oi + c]) + texture * amount).rounded().clamped(0, 255))
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

/// Extends the cover's broad colors past its edges. Copying the nearest edge pixel
/// alone stretches every edge variation into a long horizontal or vertical streak,
/// so the extension is blurred more the farther it is from the cover (a mip pyramid
/// sampled trilinearly). Next to the cover the field is unchanged; far away it becomes
/// a soft two-dimensional gradient.
enum SceneField {
    /// The widest blur is 2^maxLevel pixels.
    static let maxLevel = 6

    static func extend(_ low: ScenePixels, width: Int, height: Int, anchorX: Int, anchorY: Int) -> ScenePixels {
        let sw = low.width, sh = low.height
        var base = [Float](repeating: 0, count: width * height * 3)
        for y in 0..<height {
            let sy = (y - anchorY).clamped(0, sh - 1)
            for x in 0..<width {
                let si = (sy * sw + (x - anchorX).clamped(0, sw - 1)) * 4, oi = (y * width + x) * 3
                base[oi] = Float(low.bytes[si])
                base[oi + 1] = Float(low.bytes[si + 1])
                base[oi + 2] = Float(low.bytes[si + 2])
            }
        }
        var pyramid: [(width: Int, height: Int, data: [Float])] = [(width, height, base)]
        while pyramid.count <= maxLevel {
            let previous = pyramid[pyramid.count - 1]
            let pw = previous.width, ph = previous.height
            guard pw > 1 || ph > 1 else { break }
            let w = max(1, (pw + 1) / 2), h = max(1, (ph + 1) / 2)
            var data = [Float](repeating: 0, count: w * h * 3)
            for y in 0..<h {
                let y0 = min(ph - 1, y * 2), y1 = min(ph - 1, y * 2 + 1)
                for x in 0..<w {
                    let x0 = min(pw - 1, x * 2), x1 = min(pw - 1, x * 2 + 1)
                    for c in 0..<3 {
                        data[(y * w + x) * 3 + c] = (previous.data[(y0 * pw + x0) * 3 + c] + previous.data[(y0 * pw + x1) * 3 + c]
                            + previous.data[(y1 * pw + x0) * 3 + c] + previous.data[(y1 * pw + x1) * 3 + c]) * 0.25
                    }
                }
            }
            pyramid.append((w, h, data))
        }
        let levels = pyramid
        func sample(_ k: Int, _ x: Int, _ y: Int) -> SIMD3<Float> {
            let level = levels[k]
            let u = ((Double(x) + 0.5) * Double(level.width) / Double(width) - 0.5).clamped(0, Double(level.width - 1))
            let v = ((Double(y) + 0.5) * Double(level.height) / Double(height) - 0.5).clamped(0, Double(level.height - 1))
            let x0 = Int(u), y0 = Int(v)
            let x1 = min(level.width - 1, x0 + 1), y1 = min(level.height - 1, y0 + 1)
            let fx = Float(u - Double(x0)), fy = Float(v - Double(y0))
            func at(_ px: Int, _ py: Int) -> SIMD3<Float> {
                let i = (py * level.width + px) * 3
                return SIMD3(level.data[i], level.data[i + 1], level.data[i + 2])
            }
            let top = at(x0, y0) * (1 - fx) + at(x1, y0) * fx
            let bottom = at(x0, y1) * (1 - fx) + at(x1, y1) * fx
            return top * (1 - fy) + bottom * fy
        }
        let topLevel = Double(levels.count - 1)
        var field = ScenePixels(width: width, height: height)
        field.bytes.withUnsafeMutableBufferPointer { buffer in
            guard let out = buffer.baseAddress else { return }
            DispatchQueue.concurrentPerform(iterations: height) { y in
                for x in 0..<width {
                    let dx = max(anchorX - x, x - (anchorX + sw - 1), 0)
                    let dy = max(anchorY - y, y - (anchorY + sh - 1), 0)
                    let distance = Double(dx * dx + dy * dy).squareRoot()
                    let level = log2(max(1, distance * 0.35)).clamped(0, topLevel)
                    let k = Int(level), t = Float(level - Double(k))
                    var color = sample(k, x, y)
                    if t > 0, k + 1 < levels.count { color = color * (1 - t) + sample(k + 1, x, y) * t }
                    let oi = (y * width + x) * 4
                    out[oi] = UInt8(color.x.rounded().clamped(0, 255))
                    out[oi + 1] = UInt8(color.y.rounded().clamped(0, 255))
                    out[oi + 2] = UInt8(color.z.rounded().clamped(0, 255))
                    out[oi + 3] = 255
                }
            }
        }
        return field
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
            let left = max(0, x0 - 2), right = min(width - 1, x1 + 2)
            // Fill from all four sides, trusting the nearer pair more: wide titles fill
            // mostly from above and below, tall lettering mostly from the sides. A
            // direction whose border falls outside the image is skipped.
            var verticalWeight = y0 >= 2 && y1 + 2 < height ? 1 / Double(y1 - y0 + 2) : 0
            let horizontalWeight = x0 >= 2 && x1 + 2 < width ? 1 / Double(x1 - x0 + 2) : 0
            if verticalWeight + horizontalWeight == 0 { verticalWeight = 1 }
            let total = verticalWeight + horizontalWeight
            let original = bytes
            for y in y0...y1 {
                let fy = Double(y - y0 + 1) / Double(y1 - y0 + 2)
                for x in x0...x1 {
                    let fx = Double(x - x0 + 1) / Double(x1 - x0 + 2)
                    for channel in 0..<3 {
                        let top = Double(original[(above * width + x) * 4 + channel])
                        let bottom = Double(original[(below * width + x) * 4 + channel])
                        let leading = Double(original[(y * width + left) * 4 + channel])
                        let trailing = Double(original[(y * width + right) * 4 + channel])
                        let vertical = top * (1 - fy) + bottom * fy
                        let horizontal = leading * (1 - fx) + trailing * fx
                        let value = (vertical * verticalWeight + horizontal * horizontalWeight) / total
                        bytes[(y * width + x) * 4 + channel] = UInt8(value.rounded().clamped(0, 255))
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
