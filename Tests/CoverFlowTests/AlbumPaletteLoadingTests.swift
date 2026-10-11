import AppKit
import XCTest
@testable import CoverFlow

final class AlbumPaletteLoadingTests: XCTestCase {
    private func onMain(_ block: @escaping @MainActor () async throws -> Void) {
        let finished = expectation(description: "Album colors ready")
        Task { @MainActor in
            do { try await block() } catch { XCTFail(error.localizedDescription) }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 10)
    }

    func testPreparedPaletteUsesArtworkInsteadOfTemporaryTintAndIsCached() {
        onMain {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = ArtworkStore(directory: directory)
            var album = self.album()
            let saved = try store.save(data: self.image(red: 0.04, green: 0.05, blue: 0.06), albumID: album.id)
            album.artworkFile = saved.file
            album.tintHex = "#BDA891" // The temporary beige tint that previously flashed on screen.
            let palette = await store.albumDetailPalette(album)
            XCTAssertNotEqual(palette.background, AlbumDetailPalette.fallback(album).background)
            XCTAssertLessThan(palette.background.luminance, 0.01)
            XCTAssertNotNil(store.cachedThumbnail(album, pixels: 720))
            try FileManager.default.removeItem(at: store.fileURL(saved.file))
            let reopened = await store.albumDetailPalette(album)
            XCTAssertEqual(reopened, palette)
        }
    }

    func testArtworkReplacementInvalidatesPaletteCache() {
        onMain {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = ArtworkStore(directory: directory)
            var album = self.album()
            album.artworkFile = try store.save(data: self.image(red: 0.04, green: 0.05, blue: 0.06), albumID: album.id).file
            let original = await store.albumDetailPalette(album)
            album.artworkFile = try store.save(data: self.image(red: 1, green: 0.65, blue: 0.08), albumID: album.id).file
            album.artworkVersion += 1
            let replaced = await store.albumDetailPalette(album)
            XCTAssertNotEqual(replaced.background, original.background)
            XCTAssertGreaterThan(replaced.background.r, 0.9)
            XCTAssertGreaterThan(replaced.background.g, 0.6)
        }
    }

    func testNoArtworkAndUnreadableArtworkUseStableFallback() {
        onMain {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let store = ArtworkStore(directory: directory)
            var album = self.album()
            let noArt = await store.albumDetailPalette(album)
            XCTAssertEqual(noArt, AlbumDetailPalette.fallback(album))
            album.artworkFile = "missing.png"
            let missing = await store.albumDetailPalette(album)
            XCTAssertEqual(missing, AlbumDetailPalette.fallback(album))
        }
    }

    private func album() -> Album {
        Album(id: UUID(), groupKey: "test", title: "Album", artist: "Artist", year: nil, genre: nil,
              trackIDs: [], artworkFile: nil, artworkPixelWidth: nil, artworkPixelHeight: nil,
              artworkVersion: 0, tintHex: nil, dateAdded: Date(), lastPlayed: nil,
              isDemo: false, missingMetadata: false, userEdited: false)
    }

    private func image(red: CGFloat, green: CGFloat, blue: CGFloat) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
                                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let image = try XCTUnwrap(context.makeImage())
        return try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    }
}
