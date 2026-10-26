import AppKit
import XCTest
@testable import CoverFlow

final class ImmersiveSceneTests: XCTestCase {
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
        let color = NSColor(red:0.1,green:0.5,blue:0.8,alpha:1)
        let source = NSImage(size:NSSize(width:64,height:64),flipped:false) { bounds in color.setFill(); bounds.fill(); return true }
        let image = try XCTUnwrap(source.cgImage(forProposedRect:nil,context:nil,hints:nil))
        let frame = CGRect(x:80,y:24,width:96,height:96)
        let scene = try XCTUnwrap(AlbumSceneGenerator.generate(from:image,seed:42,analyzeText:false,
                                                              size:CGSize(width:256,height:144),coverFrame:frame))
        XCTAssertEqual(scene.width,256); XCTAssertEqual(scene.height,144)
        let pixels = NSBitmapImageRep(cgImage:scene)
        let center = try XCTUnwrap(pixels.colorAt(x:128,y:72)?.usingColorSpace(.sRGB))
        let expected = try XCTUnwrap(NSBitmapImageRep(cgImage: image).colorAt(x:32,y:32)?.usingColorSpace(.sRGB))
        XCTAssertEqual(center.blueComponent,expected.blueComponent,accuracy:0.01)
        XCTAssertEqual(center.redComponent,expected.redComponent,accuracy:0.01)
        XCTAssertEqual(center.greenComponent,expected.greenComponent,accuracy:0.01)
        XCTAssertGreaterThan(try XCTUnwrap(pixels.colorAt(x:0,y:0)).alphaComponent,0.99)
        XCTAssertNil(AlbumSceneGenerator.generate(from:image,seed:42,analyzeText:false,
                       size:CGSize(width:256,height:144),coverFrame:CGRect(x:-10,y:0,width:96,height:96)))
    }
}
