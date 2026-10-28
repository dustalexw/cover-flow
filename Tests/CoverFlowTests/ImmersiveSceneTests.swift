import AppKit
import XCTest
@testable import CoverFlow

final class ImmersiveSceneTests: XCTestCase {
    func testImmersiveStylePersistsIndependentlyAndOlderSettingsKeepTheirBehavior() throws {
        var appearance = AlbumAppearance()
        XCTAssertNil(appearance.immersiveRequestedRefinement)
        XCTAssertEqual(appearance.immersiveStyle, .extend)
        appearance.sceneRefinement = true
        appearance.refinementStyle = .ornate
        // Existing albums used Extend in immersive view, regardless of panel style.
        let oldData = try JSONEncoder().encode(appearance)
        let old = try JSONDecoder().decode(AlbumAppearance.self, from: oldData)
        XCTAssertNil(old.immersiveRefinementStyle)
        XCTAssertEqual(old.immersiveRequestedRefinement, .extend)
        let panelKey = appearance.key
        let immersiveKey = appearance.immersiveKey
        appearance.immersiveRefinementStyle = .subtle
        let restored = try JSONDecoder().decode(AlbumAppearance.self, from: JSONEncoder().encode(appearance))
        XCTAssertEqual(restored.immersiveRequestedRefinement, .subtle)
        XCTAssertEqual(restored.style, .ornate)
        XCTAssertEqual(restored.key, panelKey)
        XCTAssertNotEqual(restored.immersiveKey, immersiveKey)
        appearance.sceneRefinement = false
        XCTAssertEqual(appearance.immersiveRequestedRefinement, .subtle)
    }

    func testImmersiveStyleKeysSeparateSavedChoicesAndInvalidateArtworkAndLayout() throws {
        var album = record()
        let layout = try XCTUnwrap(ImmersiveSceneLayout.make(viewport: CGSize(width: 256, height: 144),
                                     cover: CGRect(x: 80, y: 24, width: 96, height: 96)))
        let base = AlbumSceneStore.immersiveKey(for: album, layout: layout)
        var keys: Set<String> = []
        for style in SceneRefinementStyle.allCases {
            album.appearance = AlbumAppearance(immersiveRefinementStyle: style)
            let key = AlbumSceneStore.immersiveKey(for: album, layout: layout)
            XCTAssertNotEqual(key, base)
            keys.insert(key)
        }
        XCTAssertEqual(keys.count, 3)
        let previous = AlbumSceneStore.immersiveKey(for: album, layout: layout)
        album.artworkVersion += 1
        XCTAssertNotEqual(AlbumSceneStore.immersiveKey(for: album, layout: layout), previous)
        let resized = try XCTUnwrap(ImmersiveSceneLayout.make(viewport: CGSize(width: 512, height: 288),
                                      cover: CGRect(x: 160, y: 48, width: 192, height: 192)))
        XCTAssertNotEqual(AlbumSceneStore.immersiveKey(for: album, layout: resized),
                          AlbumSceneStore.immersiveKey(for: album, layout: layout))
    }

    func testDiskCacheKeepsOtherStylesAndBoundsEachStyleToOneLayout() async throws {
        guard !AlbumSceneRefiner.isAvailable else { throw XCTSkip("Exercises the lightweight fallback without model inference") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var pixels = ScenePixels(width: 48, height: 48)
        for i in stride(from: 0, to: pixels.bytes.count, by: 4) {
            pixels.bytes[i] = 80; pixels.bytes[i + 1] = 140; pixels.bytes[i + 2] = 200
        }
        let image = try XCTUnwrap(pixels.image)
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("cover.png"))
        var album = record(); album.artworkFile = "cover.png"
        let store = AlbumSceneStore(artworkDirectory: directory)
        let layout = ImmersiveSceneLayout(size: CGSize(width: 256, height: 144), cover: CGRect(x: 80, y: 24, width: 96, height: 96))
        let sceneDirectory = directory.appendingPathComponent("Scenes")
        for style in SceneRefinementStyle.allCases {
            album.appearance = AlbumAppearance(immersiveRefinementStyle: style)
            let scene = await store.immersiveScene(for: album, layout: layout)
            XCTAssertNotNil(scene)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sceneDirectory.path).count, 3)
        let resized = ImmersiveSceneLayout(size: CGSize(width: 300, height: 160), cover: CGRect(x: 100, y: 24, width: 96, height: 96))
        let scene = await store.immersiveScene(for: album, layout: resized)
        XCTAssertNotNil(scene)
        let files = try FileManager.default.contentsOfDirectory(atPath: sceneDirectory.path)
        XCTAssertEqual(files.count, 3)
        XCTAssertTrue(files.contains(AlbumSceneStore.immersiveKey(for: album, layout: resized) + ".png"))
        album.artworkVersion += 1
        let replacement = await store.immersiveScene(for: album, layout: layout)
        XCTAssertNotNil(replacement)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sceneDirectory.path).count, 1)
    }

    private func record() -> Album {
        Album(id: UUID(), groupKey: "record", title: "Record", artist: "Artist", year: nil, genre: nil,
              trackIDs: [], artworkFile: nil, artworkPixelWidth: nil, artworkPixelHeight: nil, artworkVersion: 0,
              tintHex: nil, dateAdded: Date(), lastPlayed: nil, isDemo: false, missingMetadata: false, userEdited: false)
    }

    func testSceneAlignsCoverAndBoundsItsResolutionForWideAndPortraitViews() throws {
        for viewport in [CGSize(width: 3840,height:2160),CGSize(width:900,height:1400),CGSize(width:1200,height:800)] {
            let cover = CGRect(x: viewport.width * 0.25, y: viewport.height * 0.1,
                               width: viewport.width * 0.5, height: viewport.height * 0.75)
            let layout = try XCTUnwrap(ImmersiveSceneLayout.make(viewport: viewport, cover: cover))
            XCTAssertLessThanOrEqual(layout.size.width,2160)
            XCTAssertLessThanOrEqual(layout.size.height,1320)
            XCTAssertEqual(layout.cover.midX / layout.size.width, cover.midX / viewport.width, accuracy:0.002)
            XCTAssertEqual(layout.cover.midY / layout.size.height, cover.midY / viewport.height, accuracy:0.002)
            XCTAssertTrue(CGRect(origin:.zero,size:layout.size).contains(layout.cover))
        }
        XCTAssertNil(ImmersiveSceneLayout.make(viewport: CGSize(width:CGFloat.infinity,height:400),cover:.zero))
    }
    func testCenteredExtensionFillsCanvasWithoutMovingPreservedCover() throws {
        // An explicit sRGB fixture avoids NSImage's display-dependent drawing
        // profile and checks two distinct areas of the preserved artwork.
        var bytes = [UInt8](repeating: 255, count: 64 * 64 * 4)
        for y in 0..<64 { for x in 0..<64 {
            let i = (y * 64 + x) * 4
            bytes[i] = x < 32 ? 26 : 204
            bytes[i + 1] = 128
            bytes[i + 2] = x < 32 ? 204 : 26
        } }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(width: 64, height: 64, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: 256, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let frame = CGRect(x:80,y:24,width:96,height:96)
        let scene = try XCTUnwrap(AlbumSceneGenerator.generate(from:image,seed:42,analyzeText:false,
                                                              size:CGSize(width:256,height:144),coverFrame:frame))
        XCTAssertEqual(scene.width,256); XCTAssertEqual(scene.height,144)
        XCTAssertEqual(scene.colorSpace?.name, CGColorSpace.sRGB)
        let data = try XCTUnwrap(scene.dataProvider?.data)
        let pixels = try XCTUnwrap(CFDataGetBytePtr(data))
        for (x, red, blue) in [(104, 26.0, 204.0), (152, 204.0, 26.0)] {
            let offset = 72 * scene.bytesPerRow + x * 4
            XCTAssertEqual(Double(pixels[offset]), red, accuracy: 1)
            XCTAssertEqual(Double(pixels[offset + 1]), 128, accuracy: 1)
            XCTAssertEqual(Double(pixels[offset + 2]), blue, accuracy: 1)
            XCTAssertEqual(pixels[offset + 3], 255)
        }
        XCTAssertEqual(pixels[3], 255)
        XCTAssertNil(AlbumSceneGenerator.generate(from:image,seed:42,analyzeText:false,
                       size:CGSize(width:256,height:144),coverFrame:CGRect(x:-10,y:0,width:96,height:96)))
    }
}
