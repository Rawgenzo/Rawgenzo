import XCTest
import CoreImage
@testable import RAWCore

/// 傾きの推定。CropStage で既知の角度だけ回した画像から、それを打ち消す角度が返るか(向きの取り違えを防ぐ)
final class TiltEstimatorTests: XCTestCase {
    /// 白地に黒い格子と、向きのばらばらな短い線(本物の写真の雑音の代わり)
    private func grid(width: Int = 900, height: Int = 600) -> CIImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 1)); ctx.setLineWidth(3)
        for x in stride(from: 60, to: width, by: 120) { ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: height)) }
        for y in stride(from: 50, to: height, by: 100) { ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: width, y: y)) }
        ctx.strokePath()
        var rng = SystemRandomNumberGenerator()
        ctx.setLineWidth(2)
        for _ in 0..<40 {
            let p = CGPoint(x: Double.random(in: 0...Double(width), using: &rng), y: Double.random(in: 0...Double(height), using: &rng))
            let a = Double.random(in: 0..<(2 * .pi), using: &rng)
            ctx.move(to: p); ctx.addLine(to: CGPoint(x: p.x + 30 * cos(a), y: p.y + 30 * sin(a)))
        }
        ctx.strokePath()
        return CIImage(cgImage: ctx.makeImage()!)
    }

    /// 傾き a で回した(写真が a だけ時計回りに傾いた)画像 → 直す角度は −a
    private func rotated(_ image: CIImage, _ a: Double) -> CIImage {
        var s = DevelopSettings()
        s.crop = CropSettings(angle: a)
        // 回した四隅の透明な所を避けて中央を使う
        let out = CropStage().apply(image, settings: s, options: RenderOptions(cropMode: .rotateOnly))
        let e = image.extent
        return out.cropped(to: e.insetBy(dx: e.width * 0.15, dy: e.height * 0.15))
    }

    /// 長い線(格子)の角度から、傾けた量を打ち消す角度が出る
    private func estimate(_ image: CIImage) -> (h: Double?, v: Double?, segments: [TiltEstimator.Segment]) {
        let segs = TiltEstimator.segments(in: image)
        let long = segs.filter { $0.length > 0.5 }   // 格子の線は交点で途切れても、つなげば画像の幅いっぱいになる
        return (TiltEstimator.combinedAngle(long.filter { $0.axis == .horizontal })?.angle,
                TiltEstimator.combinedAngle(long.filter { $0.axis == .vertical })?.angle, segs)
    }

    func testRecoversKnownRotation() {
        for a in [-3.0, -1.2, 0, 0.8, 2.5] {
            let e = estimate(rotated(grid(), a))
            XCTAssertEqual(e.h ?? .nan, -a, accuracy: 0.15, "水平の線 \(a)")
            XCTAssertEqual(e.v ?? .nan, -a, accuracy: 0.15, "垂直の線 \(a)")
            for s in e.segments where s.length > 0.5 {
                XCTAssertEqual(s.angle, -a, accuracy: 0.3, "1 本ずつでも近い \(s)")
            }
        }
    }

    /// 番号は長い順で、呼ぶたびに同じ(AI が前の結果の番号を渡すため)
    func testSegmentIDsAreStable() {
        let image = rotated(grid(), 1.5)
        let a = TiltEstimator.segments(in: image), b = TiltEstimator.segments(in: image)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.map(\.id), Array(1...a.count))
        XCTAssertEqual(a.map(\.length), a.map(\.length).sorted(by: >))
        XCTAssertLessThanOrEqual(a.count, TiltEstimator.maxSegmentsPerAxis * 2)
        XCTAssertTrue(a.contains { $0.axis == .vertical } && a.contains { $0.axis == .horizontal }, "両方の向きが入る")
    }

    /// 直す角度を当てると、ほぼ水平になる(CropSettings.angle の向きと合っている)
    func testApplyingTheEstimateLevelsTheImage() {
        let tilted = rotated(grid(), 2)
        let fix = estimate(tilted).h!
        XCTAssertEqual(estimate(rotated(tilted, fix)).h!, 0, accuracy: 0.15)
    }

    func testNoLinesGivesNoEstimate() {
        let flat = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 300))
        XCTAssertTrue(TiltEstimator.segments(in: flat).isEmpty)
    }

    /// 縦の線が左右で開いているとき、中央での値を返す。開いていなければ nil
    func testVerticalFan() {
        func v(_ x: Double, _ angle: Double) -> TiltEstimator.Segment {
            TiltEstimator.Segment(id: 1, axis: .vertical, angle: angle, length: 0.2,
                                  from: CGPoint(x: x, y: 0.2), to: CGPoint(x: x, y: 0.6))
        }
        // 傾き +2°、左右で ±2° 開く
        let fan = TiltEstimator.verticalFan([v(0.1, 0.4), v(0.3, 1.2), v(0.7, 2.8), v(0.9, 3.6)])!
        XCTAssertEqual(fan.angleAtCenter, 2, accuracy: 1e-9)
        XCTAssertEqual(fan.angleAtLeft, 0, accuracy: 1e-9)
        XCTAssertEqual(fan.angleAtRight, 4, accuracy: 1e-9)
        XCTAssertNil(TiltEstimator.verticalFan([v(0.1, 2), v(0.3, 2.1), v(0.7, 1.9), v(0.9, 2)]), "開いていない")
        XCTAssertNil(TiltEstimator.verticalFan([v(0.4, 0), v(0.45, 1), v(0.5, 2), v(0.55, 3)]), "左右に散らばっていない")
        XCTAssertNil(TiltEstimator.verticalFan([v(0.1, 0), v(0.9, 4)]), "本数が足りない")
    }

    func testCombinedAngleWeightsByLength() {
        func seg(_ angle: Double, _ length: Double) -> TiltEstimator.Segment {
            TiltEstimator.Segment(id: 1, axis: .horizontal, angle: angle, length: length, from: .zero, to: .zero)
        }
        let c = TiltEstimator.combinedAngle([seg(1, 0.3), seg(-1, 0.1)])!
        XCTAssertEqual(c.angle, 0.5, accuracy: 1e-12)
        XCTAssertGreaterThan(c.spread, 0)
        XCTAssertNil(TiltEstimator.combinedAngle([]))
    }

    /// 体の軸: 首が腰の右上にある(上が右に倒れた)人は、反時計回り(負の角度)に回すと立つ
    func testTorsoSign() {
        let size = CGSize(width: 1000, height: 800)
        let m = TiltEstimator.torso(top: CGPoint(x: 510, y: 600), bottom: CGPoint(x: 500, y: 400), size)!
        XCTAssertEqual(m.kind, .torso)
        XCTAssertEqual(m.angle, -atan2(10, 200) * 180 / .pi, accuracy: 1e-9)
        XCTAssertNil(TiltEstimator.torso(top: CGPoint(x: 500, y: 300), bottom: CGPoint(x: 500, y: 400), size), "首が腰より下")
        XCTAssertNil(TiltEstimator.torso(top: CGPoint(x: 700, y: 450), bottom: CGPoint(x: 500, y: 400), size), "寝ている")
        // 回すと本当に立つか: 体の軸を角度ぶん回した点で確かめる(CropSettings.angle は正 = 時計回り)
        let t = m.angle * .pi / 180   // 時計回りに t 回す = 上向き y の座標で −t 回す
        let (dx, dy) = (10.0, 200.0)
        let rx = dx * cos(-t) - dy * sin(-t)
        XCTAssertEqual(rx, 0, accuracy: 1e-9, "回した後の体の軸が垂直")
    }

    /// 人物の線: Vision の座標(左下原点)で右上がりの線は、時計回りに回すと水平になる(正の角度)
    func testSubjectMarkSign() {
        let size = CGSize(width: 1000, height: 800)
        let m = TiltEstimator.mark(.eyes, CGPoint(x: 400, y: 500), CGPoint(x: 500, y: 510), size)!
        XCTAssertEqual(m.angle, atan2(10, 100) * 180 / .pi, accuracy: 1e-9)
        XCTAssertGreaterThan(m.angle, 0)
        XCTAssertEqual(Double(m.center.y), 1 - 505.0 / 800, accuracy: 1e-9, "中点は左上原点の比率")
        // 左右の順は問わない
        XCTAssertEqual(TiltEstimator.mark(.eyes, CGPoint(x: 500, y: 510), CGPoint(x: 400, y: 500), size)!.angle, m.angle, accuracy: 1e-9)
        XCTAssertNil(TiltEstimator.mark(.eyes, CGPoint(x: 400, y: 500), CGPoint(x: 410, y: 560), size), "縦に近い線は手がかりにしない")
    }
}
