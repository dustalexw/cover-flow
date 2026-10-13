import AppKit
import XCTest
@testable import CoverFlow

/// Covers the model-independent parts of Stable Diffusion scene refinement.
final class SceneRefinementTests: XCTestCase {
    func testTilesAreSquareCoverTheWholeSceneAndOverlap() {
        let tiles = SceneRefinementLayout.tiles(width: 2160, height: 1320)
        XCTAssertEqual(tiles, [CGRect(x: 0, y: 0, width: 1320, height: 1320),
                               CGRect(x: 840, y: 0, width: 1320, height: 1320)])
        XCTAssertEqual(SceneRefinementLayout.tiles(width: 512, height: 512), [CGRect(x: 0, y: 0, width: 512, height: 512)])
        // An exact multiple still overlaps rather than meeting edge to edge.
        XCTAssertEqual(SceneRefinementLayout.tiles(width: 200, height: 100).map(\.minX), [0, 50, 100])
        let tall = SceneRefinementLayout.tiles(width: 300, height: 1000)
        XCTAssertEqual(tall.count, 5)
        XCTAssertEqual(tall.first?.minY, 0)
        XCTAssertEqual(tall.last?.maxY, 1000)
        XCTAssertTrue(tall.allSatisfy { $0.width == 300 && $0.height == 300 })
        XCTAssertEqual(SceneRefinementLayout.tiles(width: 0, height: 10), [])
    }

    func testCoverRectMatchesWhereGenerationPreservesTheCover() throws {
        let size = CGSize(width: 480, height: 300)
        XCTAssertEqual(AlbumSceneGenerator.coverRect(imageWidth: 96, imageHeight: 96, size: size),
                       CGRect(x: Int(480.0 * 0.77) - 48, y: (300 - 96) / 2, width: 96, height: 96))
        XCTAssertEqual(AlbumSceneGenerator.coverRect(imageWidth: 1024, imageHeight: 1024),
                       CGRect(x: 1279, y: 276, width: 768, height: 768))
    }

    func testCompositeBlendsTilesKeepsCoverAndAddsBackFineDetail() throws {
        // Scene: a one-pixel grey checker (detail finer than the model sees) with a red cover.
        // It is larger than 512 pixels high so the detail pass has something to restore.
        let width = 1200, height = 600
        var scene = ScenePixels(width: width, height: height)
        let cover = CGRect(x: 900, y: 180, width: 240, height: 240)
        for y in 0..<height { for x in 0..<width {
            let i = (y * width + x) * 4
            if cover.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) {
                scene.bytes[i] = 250; scene.bytes[i + 1] = 0; scene.bytes[i + 2] = 0
            } else {
                let v: UInt8 = (x + y).isMultiple(of: 2) ? 140 : 100
                scene.bytes[i] = v; scene.bytes[i + 1] = v; scene.bytes[i + 2] = v
            }
        } }
        func flat(_ value: UInt8) throws -> CGImage {
            var tile = ScenePixels(width: 64, height: 64)
            for i in stride(from: 0, to: tile.bytes.count, by: 4) {
                tile.bytes[i] = value; tile.bytes[i + 1] = value; tile.bytes[i + 2] = value
            }
            return try XCTUnwrap(tile.image)
        }
        let layout = SceneRefinementLayout.tiles(width: width, height: height)
        XCTAssertEqual(layout.count, 3)
        let refined = try zip(layout, [UInt8(40), 60, 80]).map { (rect: $0.0, image: try flat($0.1)) }
        let output = try XCTUnwrap(SceneRefinementCompositor.compose(scene: scene, tiles: refined,
                                                                     cover: cover, feather: 4))
        func red(_ x: Int, _ y: Int) -> Double { Double(output.bytes[(y * width + x) * 4]) }
        // The cover is untouched.
        XCTAssertEqual(red(1000, 300), 250)
        // Away from overlaps the first tile shows through; detail averages out over a pixel pair.
        XCTAssertEqual((red(20, 50) + red(21, 50)) / 2, 40, accuracy: 3)
        // Tiles blend without a visible step anywhere left of the cover.
        let row = (0..<898).map { (red($0, 50) + red($0 + 1, 50)) / 2 }
        for (a, b) in zip(row, row.dropFirst()) { XCTAssertLessThanOrEqual(abs(a - b), 3) }
        // Fine detail from the quilted scene comes back on top of the flat tiles.
        XCTAssertGreaterThan(abs(red(20, 50) - red(21, 50)), 8)
        XCTAssertTrue(stride(from: 3, to: output.bytes.count, by: 4).allSatisfy { output.bytes[$0] == 255 })
    }

    func testRefinementSettingDecodesFromOlderSavesAndChangesKeys() throws {
        let old = try JSONEncoder().encode(AlbumAppearance())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: old) as? [String: Any])
        json.removeValue(forKey: "sceneRefinement")
        let decoded = try JSONDecoder().decode(AlbumAppearance.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(decoded.refinesScene)
        var refined = decoded
        refined.sceneRefinement = true
        XCTAssertNotEqual(decoded.key, refined.key)
        let album = Album(id: UUID(), groupKey: "record", title: "Record", artist: "Artist", year: nil, genre: nil,
                          trackIDs: [], artworkFile: nil, artworkPixelWidth: nil, artworkPixelHeight: nil, artworkVersion: 0,
                          tintHex: nil, dateAdded: Date(), lastPlayed: nil, isDemo: false, missingMetadata: false, userEdited: false)
        XCTAssertNotEqual(AlbumSceneStore.key(for: album, variation: 0),
                          AlbumSceneStore.key(for: album, variation: 0, refined: true))
        XCTAssertTrue(AlbumSceneStore.key(for: album, variation: 0, refined: true).hasSuffix(AlbumSceneStore.refinedSuffix))
    }
}
