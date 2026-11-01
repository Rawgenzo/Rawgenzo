import XCTest
import CoreImage
@testable import RAWCore

final class PreviewZoomTests: XCTestCase {
    func testFitScaleUsesPhysicalPixels() {
        // 4240×2832 を 1060×708 ポイントの領域に。Retina(2倍)なら物理ピクセルで 2120×1416 → 0.5
        let z = PreviewZoom.fitScale(imagePixels: CGSize(width: 4240, height: 2832),
                                     viewPoints: CGSize(width: 1060, height: 708), backingScale: 2)
        XCTAssertEqual(z, 0.5, accuracy: 1e-12)
        // 非Retina なら 0.25
        XCTAssertEqual(PreviewZoom.fitScale(imagePixels: CGSize(width: 4240, height: 2832),
                                            viewPoints: CGSize(width: 1060, height: 708), backingScale: 1),
                       0.25, accuracy: 1e-12)
        // 縦長の領域では幅で決まる。余白の分だけ小さくなる
        let p = PreviewZoom.fitScale(imagePixels: CGSize(width: 3000, height: 2000),
                                     viewPoints: CGSize(width: 320, height: 1000), backingScale: 1, padding: 10)
        XCTAssertEqual(p, 300.0 / 3000, accuracy: 1e-12)
    }

    func testZoomInSteps() {
        XCTAssertEqual(PreviewZoom.zoomedIn(from: 0.33), 0.5)
        XCTAssertEqual(PreviewZoom.zoomedIn(from: 0.5), 1)
        XCTAssertEqual(PreviewZoom.zoomedIn(from: 0.9995), 2)   // ほぼ 100% なら次は 200%
        XCTAssertEqual(PreviewZoom.zoomedIn(from: 1.5), 2)
        XCTAssertEqual(PreviewZoom.zoomedIn(from: 4), 4)         // 最大で止まる
    }

    func testZoomOutStopsAtFit() {
        XCTAssertEqual(PreviewZoom.zoomedOut(from: 4, fitScale: 0.33), .scale(2))
        XCTAssertEqual(PreviewZoom.zoomedOut(from: 1, fitScale: 0.33), .scale(0.5))
        // 次の段 0.25 は合わせた倍率 0.33 より小さいので、ウインドウに合わせる
        XCTAssertEqual(PreviewZoom.zoomedOut(from: 0.5, fitScale: 0.33), .fit)
        // 合わせた倍率とほぼ同じ段も .fit
        XCTAssertEqual(PreviewZoom.zoomedOut(from: 1, fitScale: 0.5), .fit)
        // 大きな画面で合わせた倍率が 1 を超えていても .fit
        XCTAssertEqual(PreviewZoom.zoomedOut(from: 2, fitScale: 1.2), .fit)
    }

    func testRenderScale() {
        let preview = 2400.0 / 4240
        XCTAssertEqual(PreviewZoom.renderScale(zoom: 0.33, previewScale: preview), preview)
        XCTAssertEqual(PreviewZoom.renderScale(zoom: preview, previewScale: preview), preview)
        XCTAssertEqual(PreviewZoom.renderScale(zoom: 0.6, previewScale: preview), 1)
        XCTAssertEqual(PreviewZoom.renderScale(zoom: 4, previewScale: preview), 1)
        // 小さい画像(プレビュー用の縮小が不要)なら常に等倍
        XCTAssertEqual(PreviewZoom.renderScale(zoom: 0.2, previewScale: 1.5), 1)
    }

    func testPercentText() {
        XCTAssertEqual(PreviewZoom.percentText(1), "100%")
        XCTAssertEqual(PreviewZoom.percentText(0.3333), "33%")
    }
}
