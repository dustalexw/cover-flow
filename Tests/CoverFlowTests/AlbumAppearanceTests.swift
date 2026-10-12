import AppKit
import XCTest
@testable import CoverFlow

final class AlbumAppearanceTests: XCTestCase {
    private func album() -> Album {
        Album(id: UUID(), groupKey: "record", title: "Record", artist: "Artist", year: nil, genre: nil,
              trackIDs: [], artworkFile: nil, artworkPixelWidth: nil, artworkPixelHeight: nil, artworkVersion: 0,
              tintHex: nil, dateAdded: Date(), lastPlayed: nil, isDemo: false, missingMetadata: false, userEdited: false)
    }

    func testOldAlbumsDecodeAndCustomSettingsRoundTripWithoutChangingArtworkIdentity() throws {
        var record = album()
        let old = try JSONEncoder().encode(record)
        XCTAssertNil(try JSONDecoder().decode(Album.self, from: old).appearance)
        XCTAssertTrue(try JSONDecoder().decode(Album.self, from: old).panelAppearance.sceneEnabled)
        let coverKey = record.artworkKey
        record.appearance = AlbumAppearance(backgroundHex: "#102838", textHex: "#FFFFFF", accentHex: "#EFD4A0",
                                            sceneEnabled: true, sceneStrength: 0.8, sceneVariation: 2)
        let restored = try JSONDecoder().decode(Album.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(restored.appearance, record.appearance)
        XCTAssertEqual(restored.artworkKey, coverKey)
        var changedCover = restored
        changedCover.artworkVersion += 1
        XCTAssertNotEqual(AlbumSceneStore.key(for: restored, variation: 2), AlbumSceneStore.key(for: changedCover, variation: 2))
        XCTAssertNotEqual(AlbumSceneStore.key(for: restored, variation: 2), AlbumSceneStore.key(for: restored, variation: 3))
    }

    func testUnreadableCustomColorsAreProtectedOnDarkLightAndMiddleBackgrounds() {
        let automatic = AlbumDetailPalette(background: .black)
        for background in ["#000000", "#FFFFFF", "#777777", "#FFEE00", "#221B61"] {
            let settings = AlbumAppearance(backgroundHex: background, textHex: background, accentHex: background)
            let colors = automatic.customized(settings)
            XCTAssertEqual(colors.background.hex, background)
            for ink in [colors.foreground, colors.secondary, colors.accent] {
                XCTAssertGreaterThanOrEqual(ink.contrast(with: colors.background), 4.5)
            }
        }
        XCTAssertEqual(automatic.customized(AlbumAppearance(backgroundHex: "bad")).background, automatic.background)
        XCTAssertEqual(AlbumAppearance(sceneStrength: .nan).strength, 0.55)
        XCTAssertEqual(AlbumAppearance(sceneStrength: 10).strength, 1)
    }

    func testScenePreservesCoverContentAndGeneratesStableOpaqueSurroundings() throws {
        var cover = ScenePixels(width: 96, height: 96)
        for y in 0..<96 { for x in 0..<96 {
            let i = (y * 96 + x) * 4
            cover.bytes[i] = UInt8((x * 7 + y * 3) % 256)
            cover.bytes[i + 1] = UInt8((x * 2 + y * 11) % 256)
            cover.bytes[i + 2] = UInt8((x * 13 + y * 5) % 256)
        } }
        let image = try XCTUnwrap(cover.image)
        let first = try XCTUnwrap(AlbumSceneGenerator.generate(from: image, seed: 17, analyzeText: false, size: CGSize(width: 480, height: 300)))
        let second = try XCTUnwrap(AlbumSceneGenerator.generate(from: image, seed: 17, analyzeText: false, size: CGSize(width: 480, height: 300)))
        let variation = try XCTUnwrap(AlbumSceneGenerator.generate(from: image, seed: 99, analyzeText: false, size: CGSize(width: 480, height: 300)))
        let pixels = try XCTUnwrap(ScenePixels(image: first, width: 480, height: 300))
        XCTAssertEqual(pixels.bytes, ScenePixels(image: second, width: 480, height: 300)?.bytes)
        XCTAssertNotEqual(pixels.bytes, ScenePixels(image: variation, width: 480, height: 300)?.bytes)
        let sx = Int(480.0 * 0.77) - 48, sy = (300 - 96) / 2
        for y in 0..<96 { for x in 0..<96 {
            let output = ((sy + y) * 480 + sx + x) * 4
            let input = (y * 96 + x) * 4
            XCTAssertEqual(Array(pixels.bytes[output..<(output + 4)]), Array(cover.bytes[input..<(input + 4)]))
        } }
        XCTAssertTrue(stride(from: 3, to: pixels.bytes.count, by: 4).allSatisfy { pixels.bytes[$0] == 255 })
    }

    func testMinimumErrorSeamFollowsTextureInsteadOfAveragingTheOverlap() {
        let costs: [Double] = [90, 0, 90, 90, 90,
                               90, 90, 0, 90, 90,
                               90, 90, 90, 0, 90,
                               90, 90, 0, 90, 90]
        XCTAssertEqual(SceneQuilting.minimumCut(costs: costs, length: 4, depth: 5), [1, 2, 3, 2])
        XCTAssertEqual(SceneQuilting.minimumCut(costs: [4, 0, 8], length: 1, depth: 3), [1])
    }

    func testRetinaSceneRetainsFineArtworkDetailAndHandlesNarrowCovers() throws {
        for dimensions in [(512, 512), (32, 256), (256, 32)] {
            var cover = ScenePixels(width: dimensions.0, height: dimensions.1)
            for y in 0..<cover.height { for x in 0..<cover.width {
                let i = (y * cover.width + x) * 4
                cover.bytes[i] = x.isMultiple(of: 2) ? 220 : 20
                cover.bytes[i + 1] = y.isMultiple(of: 2) ? 200 : 40
                cover.bytes[i + 2] = 110
            } }
            let result = try XCTUnwrap(AlbumSceneGenerator.generate(from: try XCTUnwrap(cover.image), seed: 11, analyzeText: false))
            XCTAssertEqual(result.width, 2160)
            XCTAssertEqual(result.height, 1320)
            let pixels = try XCTUnwrap(ScenePixels(image: result, width: result.width, height: result.height))
            let anchorX = min(result.width - cover.width - 12, Int(Double(result.width) * 0.77) - cover.width / 2)
            let anchorY = (result.height - cover.height) / 2
            for y in 0..<cover.height { for x in 0..<cover.width {
                let oi = ((anchorY + y) * result.width + anchorX + x) * 4
                let si = (y * cover.width + x) * 4
                XCTAssertEqual(Array(pixels.bytes[oi..<(oi + 4)]), Array(cover.bytes[si..<(si + 4)]))
            } }
        }
    }

    func testSmoothCoverColorsDoNotTurnIntoPatchBlocks() throws {
        var cover = ScenePixels(width: 96, height: 96)
        for y in 0..<96 { for x in 0..<96 {
            let i = (y * 96 + x) * 4
            cover.bytes[i] = UInt8(30 + x)
            cover.bytes[i + 1] = UInt8(50 + y)
            cover.bytes[i + 2] = 90
        } }
        let image = try XCTUnwrap(AlbumSceneGenerator.generate(from: try XCTUnwrap(cover.image), seed: 19,
            analyzeText: false, size: CGSize(width: 480, height: 300)))
        let pixels = try XCTUnwrap(ScenePixels(image: image, width: 480, height: 300))
        // The text side extends the cover's left-edge colors continuously;
        // sampling brighter areas of the cover must not create colored tiles.
        for y in stride(from: 110, to: 190, by: 5) {
            let reds = stride(from: 10, to: 250, by: 5).map { Int(pixels.bytes[(y * 480 + $0) * 4]) }
            XCTAssertLessThanOrEqual(try XCTUnwrap(reds.max()) - XCTUnwrap(reds.min()), 4)
        }
    }

    func testProminentShapeIsNotRepeatedInTheExtendedTexture() throws {
        var cover = ScenePixels(width: 256, height: 256)
        for y in 0..<256 { for x in 0..<256 {
            let bright = (x - 128) * (x - 128) + (y - 128) * (y - 128) < 35 * 35
            let i = (y * 256 + x) * 4
            for c in 0..<3 { cover.bytes[i + c] = bright ? 240 : 20 }
        } }
        let image = try XCTUnwrap(AlbumSceneGenerator.generate(from: try XCTUnwrap(cover.image), seed: 17,
            analyzeText: false, size: CGSize(width: 800, height: 500)))
        let pixels = try XCTUnwrap(ScenePixels(image: image, width: 800, height: 500))
        // Even without Vision, quiet texture sampling must not clone the disk
        // into the track area far to the left of the preserved cover.
        for y in stride(from: 0, to: 500, by: 3) { for x in stride(from: 0, to: 400, by: 3) {
            XCTAssertLessThanOrEqual(pixels.bytes[(y * 800 + x) * 4], 35)
        } }
    }

    func testEveryScenePixelPreservesTextContrastAtFullStrength() throws {
        var source = ScenePixels(width: 48, height: 30)
        for i in stride(from: 0, to: source.bytes.count, by: 4) {
            source.bytes[i] = UInt8((i * 7) % 256)
            source.bytes[i + 1] = UInt8((i * 11) % 256)
            source.bytes[i + 2] = UInt8((i * 17) % 256)
        }
        for background in ["#061323", "#F5F0E2", "#777777"] {
            let colors = AlbumDetailPalette(background: .black).customized(AlbumAppearance(backgroundHex: background))
            let rendered = try XCTUnwrap(AlbumSceneRenderer.render(try XCTUnwrap(source.image), colors: colors, strength: 1))
            let pixels = try XCTUnwrap(ScenePixels(image: rendered, width: 48, height: 30))
            for i in stride(from: 0, to: pixels.bytes.count, by: 4) {
                let pixel = AlbumDetailPalette.RGB(r: Double(pixels.bytes[i]) / 255,
                                                  g: Double(pixels.bytes[i + 1]) / 255,
                                                  b: Double(pixels.bytes[i + 2]) / 255)
                for ink in [colors.foreground, colors.secondary, colors.accent] {
                    XCTAssertGreaterThanOrEqual(ink.contrast(with: pixel), 4.5)
                }
            }
        }
    }

    func testHeaderProtectionFadesWithoutAVisibleHorizontalBand() throws {
        var source = ScenePixels(width: 100, height: 300)
        for i in stride(from: 0, to: source.bytes.count, by: 4) {
            source.bytes[i] = 80; source.bytes[i + 1] = 100; source.bytes[i + 2] = 120
        }
        let colors = AlbumDetailPalette(background: .black)
        let rendered = try XCTUnwrap(AlbumSceneRenderer.render(try XCTUnwrap(source.image), colors: colors, strength: 1))
        let pixels = try XCTUnwrap(ScenePixels(image: rendered, width: 100, height: 300))
        for y in 1..<300 { for c in 0..<3 {
            let current = Int(pixels.bytes[(y * 100 + 90) * 4 + c])
            let previous = Int(pixels.bytes[((y - 1) * 100 + 90) * 4 + c])
            XCTAssertLessThanOrEqual(abs(current - previous), 1)
        } }
    }

    func testSceneLetteringCleanupDoesNotChangeTheOriginalCover() throws {
        var cover = ScenePixels(width: 32, height: 32)
        for i in stride(from: 0, to: cover.bytes.count, by: 4) {
            cover.bytes[i] = 190; cover.bytes[i + 1] = 210; cover.bytes[i + 2] = 240
        }
        for y in 12..<18 { for x in 8..<24 {
            let i = (y * 32 + x) * 4
            cover.bytes[i] = 0; cover.bytes[i + 1] = 0; cover.bytes[i + 2] = 0
        } }
        let original = cover.bytes
        var sceneSource = cover
        sceneSource.clearLettering(in: [CGRect(x: 7, y: 11, width: 18, height: 8)])
        XCTAssertEqual(cover.bytes, original)
        for y in 12..<18 { for x in 8..<24 {
            let i = (y * 32 + x) * 4
            XCTAssertEqual(Array(sceneSource.bytes[i..<(i + 3)]), [190, 210, 240])
        } }
    }

    @MainActor
    func testMissingArtworkUsesCustomColorsWithoutGeneratingAScene() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = ArtworkStore(directory: directory)
        let colors = AlbumAppearance(backgroundHex: "#142B35", textHex: "#FFFFFF", accentHex: "#FFDD88")
        let style = await store.albumPanelStyle(album(), appearance: colors)
        XCTAssertNil(style.scene)
        XCTAssertEqual(style.colors.background.hex, "#142B35")
        XCTAssertGreaterThanOrEqual(style.colors.foreground.contrast(with: style.colors.background), 4.5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Scenes").path))
    }

    func testScenesPersistAndReplacementArtworkInvalidatesTheScene() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ArtworkStore(directory: directory)
        var record = album()
        func imageData(red: CGFloat, blue: CGFloat) throws -> Data {
            let context = try XCTUnwrap(CGContext(data: nil, width: 48, height: 48, bitsPerComponent: 8,
                bytesPerRow: 192, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.setFillColor(CGColor(red: red, green: 0.1, blue: blue, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 48, height: 48))
            return try XCTUnwrap(NSBitmapImageRep(cgImage: try XCTUnwrap(context.makeImage())).representation(using: .png, properties: [:]))
        }
        record.artworkFile = try store.save(data: imageData(red: 0.8, blue: 0.1), albumID: record.id).file
        let oldDirectory = directory.appendingPathComponent("Scenes")
        try FileManager.default.createDirectory(at: oldDirectory, withIntermediateDirectories: true)
        let oldScene = oldDirectory.appendingPathComponent("\(record.artworkKey)-scene-v3-0.png")
        try imageData(red: 0.1, blue: 0.8).write(to: oldScene)
        let firstScene = await store.scenes.scene(for: record, variation: 0)
        let original = try XCTUnwrap(firstScene)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldScene.path))
        XCTAssertEqual(original.width, 2160)
        XCTAssertEqual(original.height, 1320)
        XCTAssertTrue(AlbumSceneStore.key(for: record, variation: 0).contains("-scene-v4-"))
        let restarted = AlbumSceneStore(artworkDirectory: directory)
        let diskScene = await restarted.scene(for: record, variation: 0)
        let disk = try XCTUnwrap(diskScene)
        XCTAssertEqual(ScenePixels(image: original, width: 480, height: 300)?.bytes,
                       ScenePixels(image: disk, width: 480, height: 300)?.bytes)
        record.artworkFile = try store.save(data: imageData(red: 0.1, blue: 0.8), albumID: record.id).file
        record.artworkVersion += 1
        let replacementScene = await store.scenes.scene(for: record, variation: 0)
        let replaced = try XCTUnwrap(replacementScene)
        XCTAssertNotEqual(ScenePixels(image: original, width: 480, height: 300)?.bytes,
                          ScenePixels(image: replaced, width: 480, height: 300)?.bytes)
    }
}
