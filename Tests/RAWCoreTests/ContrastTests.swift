import XCTest
import CoreImage
@testable import RAWCore

final class ContrastTests: XCTestCase {
    func testCurveKeepsEndsAndPivot() {
        for a in [-1.0, -0.4, 0.3, 1] {
            XCTAssertEqual(ContrastCurve.apply(0, amount: a), 0)
            XCTAssertEqual(ContrastCurve.apply(1, amount: a), 1)
            XCTAssertEqual(ContrastCurve.apply(ContrastCurve.pivot, amount: a), ContrastCurve.pivot, accuracy: 1e-12)
        }
        // 中間グレーはリニアで 0.18
        XCTAssertEqual(ContrastCurve.decode(ContrastCurve.pivot), 0.18, accuracy: 1e-9)
        // 0 なら何もしない
        for x in stride(from: 0.0, through: 1, by: 0.05) {
            XCTAssertEqual(ContrastCurve.apply(x, amount: 0), x, accuracy: 1e-12)
        }
    }

    func testCurveShapeAndSlope() {
        let p = ContrastCurve.pivot
        // 上げると軸より下は暗く、上は明るく(S 字)。下げると逆
        XCTAssertLessThan(ContrastCurve.apply(p * 0.5, amount: 1), p * 0.5)
        XCTAssertGreaterThan(ContrastCurve.apply(p + (1 - p) * 0.5, amount: 1), p + (1 - p) * 0.5)
        XCTAssertGreaterThan(ContrastCurve.apply(p * 0.5, amount: -1), p * 0.5)
        // 軸での傾きは 1 + 0.6 × 強さ、両端では 1 − 0.6 × 強さ
        let h = 1e-6
        for a in [-1.0, 0.5, 1] {
            let slope = (ContrastCurve.apply(p + h, amount: a) - ContrastCurve.apply(p - h, amount: a)) / (2 * h)
            XCTAssertEqual(slope, 1 + 0.6 * a, accuracy: 1e-4)
            XCTAssertEqual(ContrastCurve.apply(h, amount: a) / h, 1 - 0.6 * a, accuracy: 1e-4)
        }
        // 範囲の端(±1.2)でも右上がり(明るさの順序が入れ替わらない)
        XCTAssertEqual(ContrastCurve.range, -1.2...1.2)
        for a in [ContrastCurve.range.lowerBound, ContrastCurve.range.upperBound] {
            var last = -1.0
            for i in 0...2000 {
                let y = ContrastCurve.apply(Double(i) / 2000, amount: a)
                XCTAssertGreaterThan(y, last)
                last = y
            }
        }
        // 範囲外(HDR の 1 超え)と範囲を超えた強さ
        XCTAssertEqual(ContrastCurve.apply(1.7, amount: 1), 1.7)
        XCTAssertEqual(ContrastCurve.apply(0.3, amount: 5), ContrastCurve.apply(0.3, amount: 1.2))
        XCTAssertNotEqual(ContrastCurve.apply(0.3, amount: 1.2), ContrastCurve.apply(0.3, amount: 1))
    }

    func testLinearKeepsColorRatios() {
        let c = SIMD3(0.30, 0.12, 0.05)
        let o = ContrastCurve.applyLinear(c, amount: 0.8)
        XCTAssertEqual(o.x / o.y, c.x / c.y, accuracy: 1e-12)
        XCTAssertEqual(o.z / o.y, c.z / c.y, accuracy: 1e-12)
        XCTAssertEqual(ContrastCurve.applyLinear(SIMD3(0, 0, 0), amount: 1), SIMD3(0, 0, 0))
    }

    func testSettingsDefaultAndOldSidecar() throws {
        XCTAssertEqual(DevelopSettings().contrast, 0)
        let old = #"{"schemaVersion": 2, "exposure": 0.3}"#.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(DevelopSettings.self, from: old).contrast, 0)
        let v = #"{"contrast": -0.25}"#.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(DevelopSettings.self, from: v).contrast, -0.25)
        // 型が違っていても全体の読み込みは失敗しない
        let broken = #"{"exposure": 1, "contrast": "high"}"#.data(using: .utf8)!
        let b = try JSONDecoder().decode(DevelopSettings.self, from: broken)
        XCTAssertEqual(b.exposure, 1)
        XCTAssertEqual(b.contrast, 0)
    }

    /// GPU のカーネルが CPU の計算と同じ値を出すこと。一部だけ描いた場合(入出力の範囲がずれる)も
    func testGPUMatchesCPU() throws {
        let w = 64, h = 48
        var px = [Float](repeating: 1, count: w * h * 4)
        func color(_ x: Int, _ y: Int) -> SIMD3<Double> {
            // 位置ごとに違う色・明るさ(暗部〜1 超えまで)
            SIMD3(Double(x) / Double(w) * 1.3, Double(y) / Double(h), Double((x * 7 + y * 3) % 17) / 17)
        }
        for row in 0..<h {
            for x in 0..<w {
                let c = color(x, h - 1 - row)   // ビットマップの 1 行目は上端
                let i = (row * w + x) * 4
                px[i] = Float(c.x); px[i + 1] = Float(c.y); px[i + 2] = Float(c.z)
            }
        }
        let image = CIImage(bitmapData: px.withUnsafeBufferPointer { Data(buffer: $0) }, bytesPerRow: w * 16,
                            size: CGSize(width: w, height: h), format: .RGBAf, colorSpace: nil)
        var s = DevelopSettings()
        s.contrast = 0.9
        let out = ContrastStage().apply(image, settings: s, options: RenderOptions())
        XCTAssertFalse(out === image)
        let ctx = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        for (x, y) in [(3, 5), (40, 30), (63, 47), (20, 0), (50, 10)] {
            var p = [Float](repeating: 0, count: 4)
            ctx.render(out, toBitmap: &p, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1),
                       format: .RGBAf, colorSpace: nil)
            let expected = ContrastCurve.applyLinear(color(x, y), amount: 0.9)
            for k in 0..<3 {
                XCTAssertEqual(Double(p[k]), expected[k], accuracy: max(2e-3, expected[k] * 2e-3), "(\(x), \(y)) ch\(k)")
            }
        }
        // 0 なら元の画像をそのまま返す
        XCTAssertTrue(ContrastStage().apply(image, settings: DevelopSettings(), options: RenderOptions()) === image)
    }
}
