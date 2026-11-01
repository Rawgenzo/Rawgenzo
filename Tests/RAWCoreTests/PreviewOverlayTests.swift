import XCTest
import CoreImage
@testable import RAWCore

/// AI に見せる画像への枠・ガイドの描き込み(左上原点の比率の座標で、狙った位置に描けているか)
final class PreviewOverlayTests: XCTestCase {
    private let gray = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 300, height: 200))

    /// 左上原点の (x, y) ピクセルの RGB(0...255)
    private func pixel(_ image: CIImage, _ x: Int, _ y: Int) -> [Int] {
        let ctx = CIContext()
        var px = [UInt8](repeating: 0, count: 4)
        let h = Int(image.extent.height)
        ctx.render(image, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: x, y: h - 1 - y, width: 1, height: 1),
                   format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return px.prefix(3).map(Int.init)
    }

    func testFrameDimsOutsideOnly() throws {
        let out = try PreviewOverlay.draw(on: gray, frame: CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5))
        XCTAssertEqual(out.extent.size, gray.extent.size)
        let inside = pixel(out, 225, 50), outside = pixel(out, 75, 150), plain = pixel(gray, 225, 50)
        XCTAssertEqual(inside, plain, "枠の中は元のまま")
        XCTAssertLessThan(outside[0], plain[0] - 40, "枠の外は暗い(左下)")
        XCTAssertLessThan(pixel(out, 225, 150)[0], plain[0] - 40, "枠の下(右下)も暗い。上下が逆なら明るいまま")
    }

    func testGuideIsDrawnInsideTheFrame() throws {
        let frame = CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)   // 右上の 150×100
        let out = try PreviewOverlay.draw(on: gray, frame: frame, guides: [CompositionGuides.thirds])
        // 枠の中の三分割の縦線: x = 150 + 150/3 = 200。線の色(黄色)で、青が低い
        let onLine = pixel(out, 200, 70)
        XCTAssertGreaterThan(onLine[0], 200)
        XCTAssertLessThan(onLine[2], 150)
        XCTAssertEqual(pixel(out, 225, 70), pixel(gray, 225, 70), "線の無い所は元のまま")
    }
}
