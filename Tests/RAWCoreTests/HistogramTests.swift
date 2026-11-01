import XCTest
import CoreImage
@testable import RAWCore

/// 調整パネルのヒストグラム
final class HistogramTests: XCTestCase {
    /// 左半分が純粋な赤(255,0,0)、右半分が灰色(128)の画像
    func testCountsChannelsAndClipping() throws {
        let ctx = CGContext(data: nil, width: 100, height: 50, bitsPerComponent: 8, bytesPerRow: 400,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 50, height: 50))
        ctx.setFillColor(CGColor(srgbRed: 128 / 255, green: 128 / 255, blue: 128 / 255, alpha: 1)); ctx.fill(CGRect(x: 50, y: 0, width: 50, height: 50))
        let h = try XCTUnwrap(Histogram.compute(ctx.makeImage()!, step: 1))
        XCTAssertEqual(h.red.reduce(0, +), 1, accuracy: 1e-9)
        XCTAssertEqual(h.red[255], 0.5, accuracy: 0.01)
        XCTAssertEqual(h.red[128], 0.5, accuracy: 0.01)
        XCTAssertEqual(h.green[0], 0.5, accuracy: 0.01)
        XCTAssertEqual(h.highlightClipping, 0.5, accuracy: 0.01, "赤の 255 は白飛びに数える")
        XCTAssertEqual(h.shadowClipping, 0.5, accuracy: 0.01)
        XCTAssertEqual(h.luminance[128], 0.5, accuracy: 0.01)
    }
}
