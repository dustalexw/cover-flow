import Foundation
import CoreGraphics
import ImageIO

/// Fully decoded immutable pixels are safe to share. AppKit images are created
/// only by the main actor, never sent out of a background task.
struct DecodedArtwork: @unchecked Sendable {
    let image: CGImage
}

/// A hard byte budget rather than NSCache's advisory cost limit. The UI can
/// synchronously retrieve an already decoded cover without doing disk I/O.
final class ArtworkRasterCache: @unchecked Sendable {
    private struct Entry { let artwork: DecodedArtwork; let cost: Int; var access: UInt64 }
    private struct Partition {
        var entries: [String: Entry] = [:]
        var cost = 0
        let budget: Int
        let countLimit: Int
    }
    private let lock = NSLock()
    private var thumbnails: Partition
    private var full: Partition
    private var clock: UInt64 = 0

    init(thumbnailBytes: Int = 192 * 1024 * 1024, fullBytes: Int = 96 * 1024 * 1024,
         countLimit: Int = 512) {
        thumbnails = Partition(budget: max(0, thumbnailBytes), countLimit: max(1, countLimit))
        full = Partition(budget: max(0, fullBytes), countLimit: 3)
    }

    private static func key(_ url: URL, _ pixels: Int) -> String { url.standardizedFileURL.path + "@\(pixels)" }

    func value(for url: URL, pixels: Int) -> DecodedArtwork? {
        lock.lock(); defer { lock.unlock() }
        clock &+= 1
        let key = Self.key(url, pixels)
        if pixels > 1100 {
            guard var entry = full.entries[key] else { return nil }
            entry.access = clock; full.entries[key] = entry
            return entry.artwork
        }
        guard var entry = thumbnails.entries[key] else { return nil }
        entry.access = clock; thumbnails.entries[key] = entry
        return entry.artwork
    }

    func insert(_ artwork: DecodedArtwork, for url: URL, pixels: Int) {
        let size = artwork.image.bytesPerRow.multipliedReportingOverflow(by: artwork.image.height)
        guard !size.overflow else { return }
        var retired: [DecodedArtwork] = []
        lock.lock()
        clock &+= 1
        let key = Self.key(url, pixels), access = clock
        func insert(into partition: inout Partition) {
            guard size.partialValue <= partition.budget else { return }
            if let old = partition.entries.removeValue(forKey: key) {
                partition.cost -= old.cost; retired.append(old.artwork)
            }
            partition.entries[key] = Entry(artwork: artwork, cost: size.partialValue, access: access)
            partition.cost += size.partialValue
            while partition.cost > partition.budget || partition.entries.count > partition.countLimit {
                guard let oldest = partition.entries.min(by: { $0.value.access < $1.value.access }),
                      let removed = partition.entries.removeValue(forKey: oldest.key) else { break }
                partition.cost -= removed.cost; retired.append(removed.artwork)
            }
        }
        if pixels > 1100 { insert(into: &full) } else { insert(into: &thumbnails) }
        lock.unlock()
        // Releasing large rasters must not extend the lock taken by UI lookups.
        withExtendedLifetime(retired) {}
    }
}

/// Serializes expensive ImageIO work on its own executor. Concurrent requests
/// for the same immutable artwork version share the cache, while canceled view
/// tasks are skipped before opening files. No detached-task fan-out on scrolling.
actor ArtworkDecoder {
    typealias Decode = @Sendable (URL, Int) -> CGImage?
    private let cache: ArtworkRasterCache
    private let decode: Decode

    init(cache: ArtworkRasterCache, decode: @escaping Decode = ArtworkDecoder.decodeImage) {
        self.cache = cache; self.decode = decode
    }

    func image(at url: URL, pixels: Int) -> DecodedArtwork? {
        guard !Task.isCancelled else { return nil }
        if let cached = cache.value(for: url, pixels: pixels) { return cached }
        guard let image = decode(url, pixels) else { return nil }
        let result = DecodedArtwork(image: image)
        cache.insert(result, for: url, pixels: pixels)
        return Task.isCancelled ? nil : result
    }

    nonisolated static func decodeImage(at url: URL, pixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels
        ] as CFDictionary)
    }
}
