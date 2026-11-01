import XCTest
import CoreImage
@testable import RAWCore

/// トーンカーブ(ToneCurveSettings・ToneCurveFunction・ToneCurveStage)
final class ToneCurveTests: XCTestCase {
    func testFunctionPassesThroughPointsWithoutOvershoot() {
        let pts = [CurvePoint(0, 0), CurvePoint(0.2, 0.1), CurvePoint(0.3, 0.6), CurvePoint(0.7, 0.62), CurvePoint(1, 1)]
        let f = ToneCurveFunction(pts)
        for p in pts { XCTAssertEqual(f(p.x), p.y, accuracy: 1e-12) }
        // 点の値が上がり続けるなら、間でも下がらない(行き過ぎて山や谷を作らない)
        var prev = -1.0
        for i in 0...1000 {
            let y = f(Double(i) / 1000)
            XCTAssertGreaterThanOrEqual(y, prev - 1e-12)
            prev = y
        }
        // 0.3〜0.7 の間はほぼ平らな区間。0.6〜0.62 の外に出ない
        for i in 0...100 {
            let y = f(0.3 + 0.4 * Double(i) / 100)
            XCTAssertGreaterThanOrEqual(y, 0.6 - 1e-9); XCTAssertLessThanOrEqual(y, 0.62 + 1e-9)
        }
        // 変えていないカーブはそのまま、0〜1 の外は傾き 1 で伸ばす
        let id = ToneCurveFunction(ToneCurveSettings.identity)
        XCTAssertEqual(id(0.37), 0.37, accuracy: 1e-12)
        let lifted = ToneCurveFunction([CurvePoint(0, 0.1), CurvePoint(1, 0.9)])
        XCTAssertEqual(lifted(1.5), 0.9 + 0.5 * 0.8, accuracy: 1e-12, "端の接線(傾き 0.8)で伸ばす")
        XCTAssertEqual(lifted(-0.2), 0.1 - 0.2 * 0.8, accuracy: 1e-12)
        // 白を寝かせたカーブでも、1 を超える明るさは下限の傾きで上がり続ける
        let flat = ToneCurveFunction([CurvePoint(0, 0), CurvePoint(0.8, 0.9), CurvePoint(1, 0.9)])
        XCTAssertEqual(flat(1.5), 0.9 + 0.5 * ToneCurveFunction.minExtensionSlope, accuracy: 1e-12)
        XCTAssertEqual(ToneCurveSettings.normalized([CurvePoint(.nan, 0.5), CurvePoint(0.5, .infinity)]), ToneCurveSettings.identity)
    }

    func testNormalized() {
        // 範囲の外・逆順・近すぎる点・端の欠け
        let n = ToneCurveSettings.normalized([CurvePoint(0.5, 1.2), CurvePoint(0.3, 0.2), CurvePoint(0.305, 0.25)])
        XCTAssertEqual(n, [CurvePoint(0, 0), CurvePoint(0.3, 0.2), CurvePoint(0.5, 1), CurvePoint(1, 1)])
        let many = (0..<30).map { CurvePoint(Double($0) / 29, Double($0) / 29) }
        let m = ToneCurveSettings.normalized(many)
        XCTAssertEqual(m.count, ToneCurveSettings.maxPoints)
        XCTAssertEqual(m.last, CurvePoint(1, 1))
        XCTAssertEqual(ToneCurveSettings.normalized([]), ToneCurveSettings.identity)
    }

    func testPresets() {
        for p in ToneCurvePreset.allCases { XCTAssertEqual(ToneCurvePreset.matching(p.points), p) }
        XCTAssertNil(ToneCurvePreset.matching([CurvePoint(0, 0), CurvePoint(0.5, 0.6), CurvePoint(1, 1)]))
        XCTAssertEqual(ToneCurvePreset.matching(ToneCurveSettings.identity), .linear)
    }

    func testCodableAndOldSidecar() throws {
        var s = DevelopSettings()
        var c = ToneCurveSettings()
        c.luma = ToneCurvePreset.medium.points
        c.blue = [CurvePoint(0, 0.1), CurvePoint(1, 1)]
        c.saturationLink = 0.4
        s.toneCurve = c
        let data = try JSONEncoder().encode(s)
        let text = String(data: data, encoding: .utf8)!
        XCTAssertFalse(text.contains("\"red\""), "変えていないチャンネルは書かない")
        XCTAssertTrue(text.contains("[0.25,0.2"), "点は [x, y] の 2 つの数")
        XCTAssertEqual(try JSONDecoder().decode(DevelopSettings.self, from: data).toneCurve, c)
        XCTAssertEqual(DevelopSettings.currentSchemaVersion, 5)
        let old = #"{"schemaVersion": 4, "exposure": 0.3}"#.data(using: .utf8)!
        XCTAssertNil(try JSONDecoder().decode(DevelopSettings.self, from: old).toneCurve)
        // 壊れていても、ほかの設定とチャンネルは読める
        let broken = #"{"exposure": 1, "toneCurve": {"luma": "x", "red": [[0, 0.1], [1, 1]]}}"#.data(using: .utf8)!
        let b = try JSONDecoder().decode(DevelopSettings.self, from: broken)
        XCTAssertEqual(b.exposure, 1)
        XCTAssertEqual(b.toneCurve?.luma, ToneCurveSettings.identity)
        XCTAssertEqual(b.toneCurve?.red, [CurvePoint(0, 0.1), CurvePoint(1, 1)])
        // 斜めの線の上に足した点は、画像を変えなくても保存して読み戻す(設定ごと消さない)
        var onDiagonal = ToneCurveSettings()
        onDiagonal.luma = [CurvePoint(0, 0), CurvePoint(0.3, 0.3), CurvePoint(1, 1)]
        XCTAssertTrue(onDiagonal.isNeutral)
        XCTAssertFalse(onDiagonal.isEmpty)
        XCTAssertTrue(ToneCurveSettings().isEmpty)
        XCTAssertEqual(try JSONDecoder().decode(ToneCurveSettings.self, from: JSONEncoder().encode(onDiagonal)), onDiagonal)
        let worse = #"{"exposure": 1, "toneCurve": 5}"#.data(using: .utf8)!
        XCTAssertNil(try JSONDecoder().decode(DevelopSettings.self, from: worse).toneCurve)
    }

    func testLumaKeepsRatiosAndLinkChangesSaturation() {
        var s = ToneCurveSettings()
        s.luma = ToneCurvePreset.strong.points
        let c = SIMD3(0.30, 0.12, 0.05)
        let o = ToneCurveMath.apply(c, .init(s))
        XCTAssertEqual(o.x / o.y, c.x / c.y, accuracy: 1e-9, "連動 0 は色の比を保つ")
        s.saturationLink = 1
        let p = ToneCurveMath.apply(c, .init(s))
        // S 字をチャンネルごとに掛けると、明るいチャンネルと暗いチャンネルの差が広がる(彩度が上がる)
        XCTAssertGreaterThan(p.x / p.z, c.x / c.z)
        // HDR の 1 超えは切らない(端の接線で伸ばすので、S 字なら少し寝る)
        XCTAssertGreaterThan(ToneCurveMath.apply(SIMD3(1.3, 1.3, 1.3), .init(s)).x, 1.1)
    }

    /// 黒を持ち上げたとき、暗い色の画素が比で何倍にもならない(真っ黒とその隣が連続する)
    func testLiftedBlackNearBlackColors() {
        var s = ToneCurveSettings()
        s.luma = [CurvePoint(0, 10.0 / 255), CurvePoint(1, 1)]
        let fs = ToneCurveMath.Functions(s)
        let black = ToneCurveMath.apply(SIMD3(0, 0, 0), fs)
        let gray = ContrastCurve.decode(10.0 / 255)
        for k in 0..<3 { XCTAssertEqual(black[k], gray, accuracy: 1e-9, "真っ黒は持ち上げた灰色に") }
        let darkBlue = ToneCurveMath.apply(SIMD3(0, 0, 0.002), fs)
        XCTAssertLessThan(darkBlue.z, 0.02, "比で掛けると約 0.5 になる")
        XCTAssertGreaterThan(darkBlue.x, 0, "黒と同じく持ち上がる")
        let tiny = ToneCurveMath.apply(SIMD3(0, 0, 1e-6), fs)
        XCTAssertEqual(tiny.x, black.x, accuracy: 1e-4)
        XCTAssertEqual(tiny.z, black.z, accuracy: 1e-4)
        // 暗さの境目(見た目の明るさ 0.05)の前後でつながっている
        let y = ContrastCurve.decode(ToneCurveMath.blackBlend) / 0.0722
        let a = ToneCurveMath.apply(SIMD3(0, 0, y * 0.999), fs), b = ToneCurveMath.apply(SIMD3(0, 0, y * 1.001), fs)
        XCTAssertEqual(a.z, b.z, accuracy: 2e-3)
    }

    /// GPU のカーネルが CPU の計算と同じ値を出すこと(表の補間の誤差の範囲で)
    func testGPUMatchesCPU() throws {
        let w = 64, h = 48
        var px = [Float](repeating: 1, count: w * h * 4)
        func color(_ x: Int, _ y: Int) -> SIMD3<Double> {
            SIMD3(Double(x) / Double(w) * 1.3, Double(y) / Double(h), Double((x * 7 + y * 3) % 17) / 17 * 0.2)
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
        var c = ToneCurveSettings()
        c.luma = [CurvePoint(0, 0.03), CurvePoint(0.3, 0.22), CurvePoint(0.7, 0.8), CurvePoint(1, 0.95)]
        c.red = [CurvePoint(0, 0), CurvePoint(0.5, 0.56), CurvePoint(1, 1)]
        c.blue = [CurvePoint(0, 0.05), CurvePoint(1, 0.9)]
        c.saturationLink = 0.3
        var s = DevelopSettings()
        s.toneCurve = c
        let out = ToneCurveStage().apply(image, settings: s, options: RenderOptions())
        XCTAssertFalse(out === image)
        let ctx = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        let fs = ToneCurveMath.Functions(c)
        for (x, y) in [(3, 5), (40, 30), (63, 47), (20, 0), (50, 10), (0, 0), (60, 46)] {
            var p = [Float](repeating: 0, count: 4)
            ctx.render(out, toBitmap: &p, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1),
                       format: .RGBAf, colorSpace: nil)
            let expected = ToneCurveMath.apply(color(x, y), fs)
            for k in 0..<3 {
                XCTAssertEqual(Double(p[k]), expected[k], accuracy: max(3e-3, expected[k] * 3e-3), "(\(x), \(y)) ch\(k)")
            }
        }
        // 変えていなければ元の画像をそのまま返す
        s.toneCurve = ToneCurveSettings()
        XCTAssertTrue(ToneCurveStage().apply(image, settings: s, options: RenderOptions()) === image)
    }
}
