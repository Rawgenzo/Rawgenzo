import XCTest
import CoreImage
@testable import RAWCore

final class CropFittingTests: XCTestCase {
    private let landscape = 1.5   // 3:2
    private let portrait = 2.0 / 3

    /// 元の比率の枠を中央に置いたとき、θ 回転した画像に収まる最大の倍率(答えが式で分かる場合)
    private func expectedScale(_ degrees: Double, aspect: Double) -> Double {
        let t = abs(degrees) * .pi / 180
        return 1 / (cos(t) + max(aspect, 1 / aspect) * sin(t))
    }

    /// 中心を保って倍率 k で拡大した枠
    private func scaled(_ c: CropSettings, _ k: Double) -> CropSettings {
        var o = c
        o.width = c.width * k; o.height = c.height * k
        o.x = c.x + c.width / 2 - o.width / 2
        o.y = c.y + c.height / 2 - o.height / 2
        return o
    }

    /// 比率に合わせて縮めるときは、中心を保ち、長すぎる辺だけを縮める
    func testShrunkToAspectKeepsCenter() {
        let c = CropSettings(x: 0.1, y: 0.2, width: 0.6, height: 0.6)
        let wide = c.shrunk(toAspect: 1, imageAspect: landscape)   // 画面上は横長なので幅を縮める
        XCTAssertEqual(wide.width * landscape / wide.height, 1, accuracy: 1e-9)
        XCTAssertEqual(wide.height, 0.6, accuracy: 1e-12)
        XCTAssertEqual(wide.x + wide.width / 2, 0.4, accuracy: 1e-12)
        let tall = c.shrunk(toAspect: 3, imageAspect: landscape)   // もっと横長にするので高さを縮める
        XCTAssertEqual(tall.width * landscape / tall.height, 3, accuracy: 1e-9)
        XCTAssertEqual(tall.width, 0.6, accuracy: 1e-12)
        XCTAssertEqual(tall.y + tall.height / 2, 0.5, accuracy: 1e-12)
    }

    func testZeroAngleLeavesCropUnchanged() {
        let c = CropSettings(x: 0.1, y: 0.2, width: 0.5, height: 0.4)
        XCTAssertEqual(c.fitted(imageAspect: landscape), c)
        XCTAssertTrue(CropSettings.full.isInsideImage(imageAspect: landscape))
    }

    func testFullFrameMatchesClosedForm() {
        for aspect in [landscape, portrait] {
            for angle in [1.0, 5, 10, 15, -7] {
                let c = CropSettings(angle: angle).fitted(imageAspect: aspect)
                let k = expectedScale(angle, aspect: aspect)
                XCTAssertEqual(c.width, k, accuracy: 1e-9, "aspect \(aspect) angle \(angle)")
                XCTAssertEqual(c.height, k, accuracy: 1e-9)
                XCTAssertEqual(c.x + c.width / 2, 0.5, accuracy: 1e-12)
                XCTAssertEqual(c.y + c.height / 2, 0.5, accuracy: 1e-12)
            }
        }
    }

    func testCenteredUsesRotatedImage() {
        let c = CropSettings.centered(aspect: .original, imageAspect: landscape, angle: 5)
        XCTAssertEqual(c.width, expectedScale(5, aspect: landscape), accuracy: 1e-9)
        XCTAssertEqual(c.aspect, .original)
        // 比率指定(16:9)も保たれる: ピクセル比での 幅/高さ
        let w = CropSettings.centered(aspect: .r16x9, imageAspect: landscape, angle: 8)
        XCTAssertEqual(w.width * landscape / w.height, 16.0 / 9, accuracy: 1e-9)
        XCTAssertTrue(w.isInsideImage(imageAspect: landscape))
    }

    func testFittedIsInsideMaximalAndKeepsCenterAndRatio() {
        let crops = [CropSettings(x: 0, y: 0, width: 1, height: 1),
                     CropSettings(x: 0.05, y: 0.1, width: 0.6, height: 0.5),
                     CropSettings(x: 0.4, y: 0.3, width: 0.55, height: 0.65),
                     CropSettings(x: 0.3, y: 0.3, width: 0.2, height: 0.2)]
        for aspect in [landscape, portrait] {
            for angle in [-15.0, -3, 2, 9, 15] {
                for var c in crops {
                    c.angle = angle
                    let f = c.fitted(imageAspect: aspect)
                    XCTAssertTrue(f.isInsideImage(imageAspect: aspect))
                    if f != c {
                        XCTAssertLessThan(f.width, c.width)
                        // 少しでも大きくすると収まらない(=最大)
                        XCTAssertFalse(scaled(f, 1.001).isInsideImage(imageAspect: aspect))
                        XCTAssertEqual(f.width / f.height, c.width / c.height, accuracy: 1e-9)
                        XCTAssertEqual(f.x + f.width / 2, c.x + c.width / 2, accuracy: 1e-9)
                        XCTAssertEqual(f.y + f.height / 2, c.y + c.height / 2, accuracy: 1e-9)
                    }
                }
            }
        }
    }

    func testOppositeAnglesAreMirrorImages() {
        let c = CropSettings(x: 0.05, y: 0.1, width: 0.6, height: 0.5, angle: 6)
        var m = c
        m.x = 1 - c.x - c.width
        m.angle = -6
        let f = c.fitted(imageAspect: landscape)
        let g = m.fitted(imageAspect: landscape)
        XCTAssertEqual(g.x, 1 - f.x - f.width, accuracy: 1e-9)
        XCTAssertEqual(g.y, f.y, accuracy: 1e-9)
        XCTAssertEqual(g.width, f.width, accuracy: 1e-9)
    }

    func testCropInTransparentCornerIsPulledInside() {
        // 15° 回すと左上の隅は透明になる。そこに置いた小さな枠は、中心が内側へ寄せられる
        let c = CropSettings(x: 0, y: 0, width: 0.1, height: 0.1, angle: 15)
        XCTAssertFalse(c.isInsideImage(imageAspect: landscape))
        let f = c.fitted(imageAspect: landscape)
        XCTAssertTrue(f.isInsideImage(imageAspect: landscape))
        XCTAssertGreaterThanOrEqual(min(f.width, f.height), 0.05 - 1e-9)
        XCTAssertGreaterThan(f.x, 0)
        XCTAssertGreaterThan(f.y, 0)
    }

    func testMaximizedGrowsToLargestPossible() {
        // 中央の小さな枠 → 元の比率の最大(式で求まる値)
        let small = CropSettings(x: 0.4, y: 0.4, width: 0.2, height: 0.2, angle: 5)
        let m = small.maximized(imageAspect: landscape)
        XCTAssertEqual(m.width, expectedScale(5, aspect: landscape), accuracy: 1e-8)
        XCTAssertEqual(m.x + m.width / 2, 0.5, accuracy: 1e-8)
        // 隅に寄った枠でも、どこか1つの角が縁に当たったところで止まらず、同じ最大の大きさまで広がる
        let off = CropSettings(x: 0.1, y: 0.1, width: 0.2, height: 0.2, angle: 5).maximized(imageAspect: landscape)
        XCTAssertTrue(off.isInsideImage(imageAspect: landscape))
        XCTAssertEqual(off.width, m.width, accuracy: 1e-8)
        XCTAssertEqual(off.width / off.height, 1, accuracy: 1e-9)   // 比率は保つ
    }

    /// オーナーの報告ケース: 16:9 で -15°、枠が右寄りのとき。中心固定だと右下の角で止まるが、
    /// 位置を動かせばもっと広げられる。広げたあとの位置は、収まる範囲で元の位置に一番近いところ
    func testMaximizedMovesOnlyAsMuchAsNeeded() {
        let start = CropSettings.centered(aspect: .r16x9, imageAspect: landscape, angle: -15)
        // 中央の最大枠を半分にして右下へ寄せる
        var c = scaled(start, 0.6)
        c = c.moved(dx: 0.2, dy: 0.1, imageAspect: landscape)
        let m = c.maximized(imageAspect: landscape)
        XCTAssertTrue(m.isInsideImage(imageAspect: landscape))
        XCTAssertEqual(m.width, start.width, accuracy: 1e-8)       // 中央に作った最大枠と同じ大きさ
        XCTAssertEqual(m.width * landscape / m.height, 16.0 / 9, accuracy: 1e-9)
        XCTAssertFalse(scaled(m, 1.001).isInsideImage(imageAspect: landscape))
        // 中心固定の広げ方(その中心で収まる最大)より大きい
        let g = CropGeometry(c, imageAspect: landscape)
        XCTAssertGreaterThan(m.width, c.width * g.maxScale(center: g.center) + 0.01)
    }

    func testMoveStopsAtEdgeAndSlides() {
        // 傾き 0 なら、右へ大きく動かすと右端に付き、縦位置は変わらない
        let c = CropSettings(x: 0.2, y: 0.3, width: 0.3, height: 0.3)
        let m = c.moved(dx: 1, dy: 0.05, imageAspect: landscape)
        XCTAssertEqual(m.x, 0.7, accuracy: 1e-9)
        XCTAssertEqual(m.y, 0.35, accuracy: 1e-9)
        // 傾きがあっても、収まった状態で縁に接して止まる
        for angle in [7.0, -7] {
            var r = c; r.angle = angle
            for (dx, dy) in [(1.0, 0.0), (-1, -1), (0.3, 1), (-1, 0.2)] {
                let m = r.moved(dx: dx, dy: dy, imageAspect: landscape)
                XCTAssertTrue(m.isInsideImage(imageAspect: landscape), "angle \(angle) d \(dx),\(dy)")
                XCTAssertEqual(m.width, r.width, accuracy: 1e-12)   // 大きさは変わらない
                XCTAssertFalse(scaled(m, 1.001).isInsideImage(imageAspect: landscape))
            }
        }
    }

    func testLimitedResizeKeepsAnchorAndStopsAtEdge() {
        // 全体を 5° で収めた枠の右下の角を、さらに外へ引っ張る(左上の角は固定)
        let start = CropSettings(x: 0.3, y: 0.3, width: 0.3, height: 0.3, angle: 5)
        var target = start
        target.width = 0.69; target.height = 0.69
        let r = CropSettings.limited(from: start, toward: target, imageAspect: landscape)
        XCTAssertTrue(r.isInsideImage(imageAspect: landscape))
        XCTAssertEqual(r.x, 0.3, accuracy: 1e-12)
        XCTAssertEqual(r.y, 0.3, accuracy: 1e-12)
        XCTAssertGreaterThan(r.width, 0.3)
        var further = r
        further.width += 0.001; further.height += 0.001
        XCTAssertFalse(further.isInsideImage(imageAspect: landscape))
    }

    /// 実際に CropStage で回転・切り抜きした画像に、透明なピクセルが残らないこと。
    /// 幾何計算の回転の向き(符号)が CropStage と合っているかの確認も兼ねる。
    func testRenderedCropHasNoTransparentPixels() {
        let image = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 300, height: 200))
        let ctx = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        let crops: [CropSettings] = [
            CropSettings(angle: 7).fitted(imageAspect: 1.5),
            CropSettings(angle: -12).fitted(imageAspect: 1.5),
            // 左上の隅・右下の隅に寄せた小さな枠(回転の向きを間違えると隅が透明になる)
            CropSettings(x: 0.3, y: 0.3, width: 0.2, height: 0.2, angle: 10)
                .moved(dx: -1, dy: -1, imageAspect: 1.5),
            CropSettings(x: 0.3, y: 0.3, width: 0.2, height: 0.2, angle: -10)
                .moved(dx: 1, dy: 1, imageAspect: 1.5),
            CropSettings(x: 0.3, y: 0.3, width: 0.2, height: 0.2, angle: 10)
                .moved(dx: 1, dy: -1, imageAspect: 1.5),
            // 右下に寄った 16:9 の枠を最大まで広げたもの
            CropSettings(x: 0.5, y: 0.5, width: 0.3, height: 0.3 * 1.5 * 9 / 16, angle: -15, aspect: .r16x9)
                .maximized(imageAspect: 1.5),
        ]
        for crop in crops {
            var s = DevelopSettings()
            s.crop = crop
            let out = CropStage().apply(image, settings: s, options: RenderOptions())
            let w = Int(out.extent.width), h = Int(out.extent.height)
            XCTAssertGreaterThan(w * h, 0)
            var px = [Float](repeating: 0, count: w * h * 4)
            ctx.render(out, toBitmap: &px, rowBytes: w * 16, bounds: out.extent, format: .RGBAf, colorSpace: nil)
            let minAlpha = stride(from: 3, to: px.count, by: 4).map { px[$0] }.min() ?? 0
            XCTAssertGreaterThan(minAlpha, 0.999, "\(crop)")
        }
    }
}
