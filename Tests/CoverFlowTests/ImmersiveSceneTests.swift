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
