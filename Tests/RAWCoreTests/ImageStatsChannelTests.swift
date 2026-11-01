import XCTest
import CoreImage
@testable import RAWCore

/// get_stats の元になる統計の、チャンネル別の白飛びとヒストグラム
final class ImageStatsChannelTests: XCTestCase {
    /// 左半分が赤だけ飽和(1, 0.3, 0.3)、右半分が灰色(0.5)
    func testChannelClippingAndHistograms() {
        var px = [Float]()
        for _ in 0..<4 { for x in 0..<8 { px += x < 4 ? [1, 0.3, 0.3, 1] : [0.5, 0.5, 0.5, 1] } }
        let s = ImageStats.fromPixels(px, width: 8, height: 4)
        XCTAssertEqual(s.channelClipping, [0.5, 0, 0], "赤だけが半分飽和")
        XCTAssertEqual(s.highlightClipping, 0.5)
        XCTAssertEqual(s.rgbHistograms.count, 3)
        XCTAssertEqual(s.rgbHistograms[0][ImageStats.histogramBins - 1], 0.5, "赤の一番明るい区間に半分")
        XCTAssertEqual(s.rgbHistograms[1].reduce(0, +), 1, accuracy: 1e-9)
    }
}
