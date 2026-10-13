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
                          AlbumSceneStore.key(for: album, variation: 0, refinement: .ornate))
        XCTAssertNotEqual(AlbumSceneStore.key(for: album, variation: 0, refinement: .subtle),
                          AlbumSceneStore.key(for: album, variation: 0, refinement: .ornate))
        XCTAssertTrue(AlbumSceneStore.key(for: album, variation: 0, refinement: .ornate).contains(AlbumSceneStore.refinedMarker))
        XCTAssertFalse(AlbumSceneStore.key(for: album, variation: 0).contains(AlbumSceneStore.refinedMarker))
        // Ornate is the default style, and changing style changes the panel key.
        XCTAssertEqual(refined.style, .ornate)
        var subtle = refined
        subtle.refinementStyle = .subtle
        XCTAssertNotEqual(refined.key, subtle.key)
        XCTAssertNil(decoded.requestedRefinement)
        XCTAssertEqual(subtle.requestedRefinement, .subtle)
    }

    func testOrnateSettingsRepaintMoreAndNameTheCoverColors() {
        let ornate = SceneRefinementSettings.settings(for: .ornate, colors: ["deep teal", "gold"])
        let subtle = SceneRefinementSettings.settings(for: .subtle, colors: [])
        XCTAssertGreaterThan(ornate.strength, subtle.strength)
        XCTAssertLessThan(ornate.detail, subtle.detail)
        XCTAssertGreaterThan(ornate.coverEcho, 0)
        XCTAssertTrue(ornate.prompt.contains("deep teal, gold"))
        XCTAssertTrue(ornate.prompt.contains("ornate"))
        XCTAssertTrue(ornate.negativePrompt.contains("text"))
        XCTAssertFalse(subtle.prompt.contains("palette"))
    }

    func testColorWordsNameTheCoversDominantColors() {
        var scene = ScenePixels(width: 100, height: 100)
        let cover = CGRect(x: 20, y: 20, width: 60, height: 60)
        for y in 0..<100 { for x in 0..<100 {
            let i = (y * 100 + x) * 4
            // Cover: blue above y = 65 (a grid-cell boundary), gold below; outside the cover: red (ignored).
            let (r, g, b): (UInt8, UInt8, UInt8) = !cover.contains(CGPoint(x: x, y: y)) ? (220, 20, 20)
                : y < 65 ? (30, 70, 200) : (230, 180, 40)
            scene.bytes[i] = r; scene.bytes[i + 1] = g; scene.bytes[i + 2] = b
        } }
        XCTAssertEqual(SceneColorWords.describe(scene, cover: cover), ["blue", "gold"])
        XCTAssertEqual(SceneColorWords.name(r: 0.02, g: 0.02, b: 0.02).0, "black")
        XCTAssertEqual(SceneColorWords.name(r: 0.1, g: 0.25, b: 0.25).0, "deep teal")
        XCTAssertEqual(SceneColorWords.describe(scene, cover: .zero), [])
    }

    func testCoverEchoMirrorsTheCoverOutwardWithoutChangingIt() throws {
        var scene = ScenePixels(width: 60, height: 20)
        let cover = CGRect(x: 30, y: 5, width: 10, height: 10)
        for y in 0..<20 { for x in 0..<60 {
            let i = (y * 60 + x) * 4
            let inCover = cover.contains(CGPoint(x: x, y: y))
            // Cover: a horizontal ramp so reflections are easy to check; outside: black.
            scene.bytes[i] = inCover ? UInt8(100 + (x - 30) * 10) : 0
        } }
        let echoed = SceneRefinementCompositor.echoCover(scene: scene, cover: cover, amount: 1)
        func red(_ x: Int, _ y: Int) -> Int { Int(echoed.bytes[(y * 60 + x) * 4]) }
        // The cover is unchanged.
        for x in 30..<40 { XCTAssertEqual(red(x, 10), 100 + (x - 30) * 10) }
        // Just left of the cover mirrors its left edge, with no seam: x=29 reflects x=30,
        // x=28 reflects x=31 (the echo fades very slightly with distance).
        XCTAssertEqual(Double(red(29, 10)), 100, accuracy: 3)
        XCTAssertEqual(Double(red(28, 10)), 110, accuracy: 4)
        // Just right mirrors the right edge: x=40 reflects x=39.
        XCTAssertEqual(Double(red(40, 10)), 190, accuracy: 4)
        // One cover width out it reflects back again: x=20 takes x=39, faded to about 89%.
        XCTAssertEqual(Double(red(20, 10)), 169, accuracy: 4)
        // Zero amount leaves the scene alone.
        XCTAssertEqual(SceneRefinementCompositor.echoCover(scene: scene, cover: cover, amount: 0).bytes, scene.bytes)
    }
}
