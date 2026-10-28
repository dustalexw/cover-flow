import CoreGraphics
import XCTest
@testable import CoverFlow

final class ArtworkDecoderTests: XCTestCase {
    private final class Probe: @unchecked Sendable {
        let lock = NSLock()
        var calls = 0, active = 0, peak = 0
        var usedMainThread = false
        func record() {
            lock.lock(); calls += 1; active += 1; peak = max(peak, active)
            usedMainThread = usedMainThread || Thread.isMainThread; lock.unlock()
            Thread.sleep(forTimeInterval: 0.002)
            lock.lock(); active -= 1; lock.unlock()
        }
    }
    private func image(_ side: Int = 16) throws -> DecodedArtwork {
        let context = try XCTUnwrap(CGContext(data: nil, width: side, height: side,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return DecodedArtwork(image: try XCTUnwrap(context.makeImage()))
    }

    @MainActor
    func testConcurrentRequestsDecodeOneArtworkVersionOnceOffMainThread() async throws {
        let raster = try image(), probe = Probe()
        let decoder = ArtworkDecoder(cache: ArtworkRasterCache()) { _, _ in probe.record(); return raster.image }
        let uiResult = await decoder.image(at: URL(fileURLWithPath: "/test/ui-request.png"), pixels: 360)
        XCTAssertNotNil(uiResult)
        let url = URL(fileURLWithPath: "/test/artwork-version.png")
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<100 { group.addTask { await decoder.image(at: url, pixels: 360) != nil } }
            for await loaded in group { XCTAssertTrue(loaded) }
        }
        XCTAssertEqual(probe.calls, 2)
        XCTAssertFalse(probe.usedMainThread)
    }

    func testScrollingDifferentCoversBoundsDecodeConcurrency() async throws {
        let raster = try image(), probe = Probe()
        let decoder = ArtworkDecoder(cache: ArtworkRasterCache()) { _, _ in probe.record(); return raster.image }
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<40 {
                group.addTask { _ = await decoder.image(at: URL(fileURLWithPath: "/test/\(index).png"), pixels: 720) }
            }
        }
        XCTAssertEqual(probe.calls, 40)
        XCTAssertEqual(probe.peak, 1)
        XCTAssertFalse(probe.usedMainThread)
    }

    @MainActor
    func testCanceledViewDoesNotOpenArtwork() async throws {
        let raster = try image(), probe = Probe()
        let decoder = ArtworkDecoder(cache: ArtworkRasterCache()) { _, _ in probe.record(); return raster.image }
        let request = Task { await decoder.image(at: URL(fileURLWithPath: "/test/canceled.png"), pixels: 720) }
        request.cancel()
        let result = await request.value
        XCTAssertNil(result)
        XCTAssertEqual(probe.calls, 0)
    }

    func testByteBudgetEvictsLeastRecentlyUsedAndSeparatesFullCovers() throws {
        let raster = try image()
        let cost = raster.image.bytesPerRow * raster.image.height
        let cache = ArtworkRasterCache(thumbnailBytes: cost * 2, fullBytes: cost)
        let urls = (0..<4).map { URL(fileURLWithPath: "/test/\($0).png") }
        cache.insert(raster, for: urls[0], pixels: 360)
        cache.insert(raster, for: urls[1], pixels: 360)
        XCTAssertNotNil(cache.value(for: urls[0], pixels: 360))
        cache.insert(raster, for: urls[2], pixels: 360)
        XCTAssertNil(cache.value(for: urls[1], pixels: 360))
        XCTAssertNotNil(cache.value(for: urls[0], pixels: 360))
        XCTAssertNotNil(cache.value(for: urls[2], pixels: 360))
        cache.insert(raster, for: urls[3], pixels: 4096)
        XCTAssertNotNil(cache.value(for: urls[3], pixels: 4096))
        XCTAssertNotNil(cache.value(for: urls[0], pixels: 360))
        cache.insert(try image(64), for: urls[1], pixels: 360)
        XCTAssertNil(cache.value(for: urls[1], pixels: 360))
        XCTAssertNotNil(cache.value(for: urls[0], pixels: 360))
    }
}
