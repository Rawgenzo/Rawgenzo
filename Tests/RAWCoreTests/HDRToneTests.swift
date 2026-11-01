import XCTest
import CoreImage
@testable import RAWCore

final class HDRToneTests: XCTestCase {
    /// 1ピクセル目の明るさ(緑チャンネル、リニア)を読む
    private func sample(_ image: CIImage, at point: CGPoint) -> Float {
        var px = [Float](repeating: 0, count: 4)
        let ctx = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        ctx.render(image, toBitmap: &px, rowBytes: 16,
                   bounds: CGRect(x: point.x, y: point.y, width: 1, height: 1),
                   format: .RGBAf, colorSpace: nil)
        return px[1]
    }

    private func flat(_ v: CGFloat) -> CIImage {
        CIImage(color: CIColor(red: v, green: v, blue: v))
            .cropped(to: CGRect(x: 0, y: 0, width: 200, height: 200))
    }

    func testStrengthLiftsShadows() {
        var s = DevelopSettings()
        s.hdr.strength = 1
        let dark = flat(0.01)
        let out = HDRToneStage().apply(dark, settings: s, options: RenderOptions())
        XCTAssertGreaterThan(sample(out, at: CGPoint(x: 100, y: 100)), 0.015)
    }

    func testStrengthLowersHighlights() {
        var s = DevelopSettings()
        s.hdr.strength = 1
        let bright = flat(0.9)
        let out = HDRToneStage().apply(bright, settings: s, options: RenderOptions())
        XCTAssertLessThan(sample(out, at: CGPoint(x: 100, y: 100)), 0.85)
    }

    func testZeroStrengthIsNoOp() {
        let img = flat(0.3)
        let out = HDRToneStage().apply(img, settings: DevelopSettings(), options: RenderOptions())
        XCTAssertEqual(sample(out, at: CGPoint(x: 50, y: 50)), 0.3, accuracy: 0.001)
    }
}
