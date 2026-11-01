import XCTest
import CoreImage
@testable import RAWCore

/// 色別補正(docs/color-grading-design.md の A)
final class ColorAdjustTests: XCTestCase {
    typealias M = ColorAdjustMath
    private let palePink = SIMD3<Double>(0.98, 0.88, 0.91)   // 桜の花びらくらいの淡いピンク
    private let white = SIMD3<Double>(0.95, 0.95, 0.95)
    private let vividRed = SIMD3<Double>(0.85, 0.1, 0.15)

    private func distance(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double { let d = a - b; return (d * d).sum().squareRoot() }

    // MARK: 保存

    func testRoundTripKeepsBandsAndPoints() throws {
        var s = DevelopSettings()
        s.colorAdjust = ColorAdjustSettings(bands: [.orange: ColorBandAdjust(hue: 12, saturation: -20, luminance: 8),
                                                    .blue: ColorBandAdjust()],   // 変えていない帯は保存しない
                                            points: [ColorPointAdjust(name: "花びら", hue: 350, chroma: 12, add: 30)])
        let data = try JSONEncoder().encode(s)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"orange\""), json)
        XCTAssertFalse(json.contains("\"blue\""), "変えていない帯は書かない")
        let back = try JSONDecoder().decode(DevelopSettings.self, from: data)
        XCTAssertEqual(back.colorAdjust?.bands[.orange], ColorBandAdjust(hue: 12, saturation: -20, luminance: 8))
        XCTAssertNil(back.colorAdjust?.bands[.blue])
        XCTAssertEqual(back.colorAdjust?.points, s.colorAdjust?.points)
        var withSamples = ColorPointAdjust.picked(hue: 350, chroma: 5, lightness: 85)
        withSamples.add = 10
        XCTAssertEqual(try JSONDecoder().decode(ColorPointAdjust.self, from: JSONEncoder().encode(withSamples)).samples,
                       [ColorSample(hue: 350, chroma: 5, lightness: 85)], "拾った色も保存する")
        XCTAssertGreaterThanOrEqual(back.schemaVersion, 4)
    }

    /// schemaVersion 3 のサイドカー(色別補正なし)と、知らない帯・壊れた形
    func testReadsOldAndUnknownShapes() throws {
        let v3 = #"{"schemaVersion":3,"exposure":0.5,"saturation":1.2}"#
        let old = try JSONDecoder().decode(DevelopSettings.self, from: Data(v3.utf8))
        XCTAssertNil(old.colorAdjust)
        XCTAssertEqual(old.saturation, 1.2)
        let unknown = #"{"colorAdjust":{"bands":{"red":{"hue":10},"teal":{"hue":5}}}}"#
        let u = try JSONDecoder().decode(DevelopSettings.self, from: Data(unknown.utf8))
        XCTAssertEqual(u.colorAdjust?.bands[.red]?.hue, 10)
        XCTAssertEqual(u.colorAdjust?.bands.count, 1, "知らない帯は読み飛ばす")
        let broken = #"{"exposure":1,"colorAdjust":"???"}"#
        let b = try JSONDecoder().decode(DevelopSettings.self, from: Data(broken.utf8))
        XCTAssertNil(b.colorAdjust)
        XCTAssertEqual(b.exposure, 1, "色別補正が壊れていてもほかは読める")
    }

    // MARK: 色の計算

    func testOKLabRoundTrip() {
        for c in [SIMD3<Double>(0, 0, 0), [1, 1, 1], [1, 0, 0], [0.2, 0.6, 0.9], palePink] {
            XCTAssertLessThan(distance(M.srgb(M.oklab(c)), c), 1e-6, "\(c)")
        }
    }

    func testBandWeightsSumToOneAndCentersAreOrdered() {
        let hues = M.bandCenters.map(\.hue)
        XCTAssertEqual(hues, hues.sorted())
        XCTAssertEqual(Set(M.bandCenters.map(\.band)), Set(ColorBand.allCases))
        for h in stride(from: 0.0, to: 360, by: 7.5) {
            XCTAssertEqual(M.bandWeights(hue: h).map(\.1).reduce(0, +), 1, accuracy: 1e-9, "\(h)")
        }
        // 帯の中心ではその帯だけ
        let red = M.bandCenters.first { $0.band == .red }!
        XCTAssertEqual(M.bandWeights(hue: red.hue).first { $0.0 == .red }?.1 ?? 0, 1, accuracy: 1e-9)
    }

    func testNeutralIsIdentity() {
        let s = ColorAdjustSettings()
        for c in [palePink, white, vividRed, SIMD3<Double>(0.3, 0.5, 0.2)] {
            XCTAssertLessThan(distance(M.apply(s, to: c), c), 1e-6)
        }
    }

    /// 帯の補正は灰色・白に効かない(設計の 8 色の 4)
    func testBandsLeaveGraysAlone() {
        let s = ColorAdjustSettings(bands: Dictionary(uniqueKeysWithValues: ColorBand.allCases.map {
            ($0, ColorBandAdjust(hue: 100, saturation: 100, luminance: 100))
        }))
        for g in [0.1, 0.5, 0.95] {
            let c = SIMD3<Double>(g, g, g)
            XCTAssertLessThan(distance(M.apply(s, to: c), c), 1e-3, "\(g)")
        }
    }

    /// 赤の色相 + は、マゼンタではなくオレンジの方へ
    func testRedHueShiftMovesTowardOrange() {
        let s = ColorAdjustSettings(bands: [.red: ColorBandAdjust(hue: 100)])
        let before = M.lch(M.oklab(vividRed)).h, after = M.lch(M.oklab(M.apply(s, to: vividRed))).h
        XCTAssertGreaterThan(M.hueDifference(after, before), 5)
    }

    /// 青の彩度 −100 は青だけを灰色にする
    func testBandSaturationAffectsOnlyThatBand() {
        let s = ColorAdjustSettings(bands: [.blue: ColorBandAdjust(saturation: -100)])
        let blue = SIMD3<Double>(0.1, 0.2, 0.9)
        XCTAssertLessThan(M.lch(M.oklab(M.apply(s, to: blue))).c, 0.01)
        XCTAssertLessThan(distance(M.apply(s, to: vividRed), vividRed), 1e-3)
    }

    /// 拾った色: 淡いピンクを拾って「色を足す」と、淡いピンクだけが変わる。白と濃い赤は変わらない
    func testPointAffectsOnlyPalePink() {
        let picked = M.lch(M.oklab(palePink))
        var p = ColorPointAdjust.picked(hue: picked.h, chroma: M.chromaLevel(picked.c), lightness: M.oklab(palePink).x * 100)
        p.add = 60
        let s = ColorAdjustSettings(points: [p])
        let out = M.apply(s, to: palePink)
        XCTAssertGreaterThan(M.lch(M.oklab(out)).c, picked.c + 0.02, "ピンク味が増す")
        XCTAssertLessThan(distance(M.apply(s, to: white), white), 1e-3, "白い雲は変えない")
        XCTAssertLessThan(distance(M.apply(s, to: vividRed), vividRed), 1e-3, "濃い赤は変えない(濃さの範囲の外)")
        XCTAssertLessThan(M.chromaLevel(picked.c), 15, "淡いピンクは濃さが低い: \(M.chromaLevel(picked.c))")
        XCTAssertGreaterThan(M.chromaLevel(M.lch(M.oklab(vividRed)).c), 70)
    }

    /// 明るさの範囲: 明るい花びらを拾うと、同じ色相・淡さの暗い色(枝)は変わらない(DSC01032 で枝が紫がかった)
    func testLightnessRangeExcludesDarkBranch() {
        let lab = M.oklab(palePink)
        let picked = M.lch(lab)
        var p = ColorPointAdjust.picked(hue: picked.h, chroma: M.chromaLevel(picked.c), lightness: lab.x * 100)
        p.add = 60
        XCTAssertGreaterThan(p.lightnessMin, 50, "明るい色を拾えば、暗い側は範囲の外")
        // 同じ色相・同じ淡さで暗い色
        let dark = M.srgb([0.4, lab.y, lab.z])
        let s = ColorAdjustSettings(points: [p])
        XCTAssertLessThan(distance(M.apply(s, to: dark), dark), 1e-3)
        XCTAssertGreaterThan(distance(M.apply(s, to: palePink), palePink), 0.02)
    }

    /// 足す色: 黄色みの花びら(暖かい光、DSC01275)を拾って、ピンクを足す
    func testAddHueTintsTowardChosenHue() {
        let warmWhite = SIMD3<Double>(0.78, 0.77, 0.72)
        let lab = M.oklab(warmWhite)
        let picked = M.lch(lab)
        var p = ColorPointAdjust.picked(hue: picked.h, chroma: M.chromaLevel(picked.c), lightness: lab.x * 100)
        p.add = 60
        p.addHue = M.lch(M.oklab(palePink)).h
        let out = M.lch(M.oklab(M.apply(ColorAdjustSettings(points: [p]), to: warmWhite)))
        XCTAssertLessThan(abs(M.hueDifference(out.h, p.addHue!)), 40, "ピンクの方へ: \(out.h)")
        XCTAssertGreaterThan(abs(M.hueDifference(picked.h, p.addHue!)), 90, "元は黄色み: \(picked.h)")
        // 古いサイドカー(addHue・明るさが無い)は、拾った色相・全部の明るさのまま
        let old = try! JSONDecoder().decode(ColorPointAdjust.self, from: Data(#"{"hue":10,"chroma":5,"add":30}"#.utf8))
        XCTAssertNil(old.addHue)
        XCTAssertEqual(old.effectiveAddHue, 10)
        XCTAssertEqual(old.lightnessMin, 0); XCTAssertEqual(old.lightnessMax, 100)
    }

    /// 変えたい色と変えたくない色から範囲を決める(AI の set_color_point)。DSC01032 で測った色
    func testFitSeparatesPetalsFromSkyAndBranch() throws {
        let petals = [SIMD3<Double>(232, 230, 233), [189, 183, 192], [172, 158, 157], [224, 222, 228]]
            .map { ColorSampler.Picked(rgb: $0 / 255) }
        let sky = ColorSampler.Picked(rgb: SIMD3(149, 161, 196) / 255)
        let branch = ColorSampler.Picked(rgb: SIMD3(95, 80, 82) / 255)   // 暗く、色相は花びらに近い
        let r = try XCTUnwrap(ColorPointAdjust.fitted(includes: petals, excludes: [sky, branch]))
        XCTAssertTrue(r.unresolved.isEmpty, "空と枝は外せる: \(r.unresolved) \(r.point)")
        func w(_ c: ColorSampler.Picked) -> Double {
            M.pointWeight(r.point, l: c.lightness / 100, c: c.chroma / 100 * M.chromaReference, h: c.hue)
        }
        XCTAssertLessThan(w(sky), 0.05); XCTAssertLessThan(w(branch), 0.05)
        let weakSet = Set(r.weakIncludes.map(\.index))
        // 真っ白に近い花びら(濃さ 2)は効きが弱いことがある。それ以外は半分以上効く
        for (i, p) in petals.enumerated() where p.chroma > 4 {
            XCTAssertFalse(weakSet.contains(i), "花びら \(i)(濃さ \(p.chroma))に効く")
        }
    }

    /// 目標の濃さ: 花びらの濃さの平均が目標に届く「色を足す」の強さを探す
    func testSolvedAddReachesTargetChroma() throws {
        let petals = [SIMD3<Double>(189, 183, 192), [172, 158, 157], [224, 222, 228]].map { ColorSampler.Picked(rgb: $0 / 255) }
        var base = try XCTUnwrap(ColorPointAdjust.fitted(includes: petals)).point
        base.addHue = 355
        let r = base.solvedAdd(includes: petals, targetChroma: 15)
        XCTAssertTrue(r.met)
        XCTAssertEqual(r.achieved, 15, accuracy: 1)
        XCTAssertGreaterThan(r.point.add, 0)
        let impossible = base.solvedAdd(includes: petals, targetChroma: 95)
        XCTAssertFalse(impossible.met)
        XCTAssertEqual(impossible.point.add, 100)
    }

    /// 背景が被写体とほとんど同じ色なら、外せないと返す(DSC01275 の壁)
    func testFitReportsInseparableBackground() throws {
        let petals = [SIMD3<Double>(168, 167, 157), [199, 199, 191], [165, 155, 142]].map { ColorSampler.Picked(rgb: $0 / 255) }
        // 壁の暗い所は明るさで外せるが、花びらと同じくらい明るい所は外せない(色相・淡さ・明るさがどれも重なる)
        let darkWall = ColorSampler.Picked(rgb: SIMD3(139, 135, 124) / 255)
        let brightWall = ColorSampler.Picked(rgb: SIMD3(182, 180, 170) / 255)
        let r = try XCTUnwrap(ColorPointAdjust.fitted(includes: petals, excludes: [darkWall, brightWall]))
        XCTAssertEqual(r.unresolved.map(\.index), [1], "明るい壁は外せない: \(r.point)")
        XCTAssertNil(ColorPointAdjust.fitted(includes: []))
    }

    /// 効く場所の表示: 拾った色はそのまま、範囲の外は灰色
    func testMaskShowsOnlyAffectedColors() {
        let picked = M.lch(M.oklab(palePink))
        let s = ColorAdjustSettings(points: [ColorPointAdjust.picked(hue: picked.h, chroma: M.chromaLevel(picked.c),
                                                                     lightness: M.oklab(palePink).x * 100)])
        XCTAssertLessThan(distance(M.mask(.point(0), s, rgb: palePink), palePink), 1e-3)
        let green = SIMD3<Double>(0.2, 0.7, 0.2)
        XCTAssertLessThan(M.lch(M.oklab(M.mask(.point(0), s, rgb: green))).c, 0.005, "範囲の外は灰色")
        XCTAssertLessThan(M.lch(M.oklab(M.mask(.band(.green), s, rgb: green))).c - M.lch(M.oklab(green)).c, 1e-3)
    }

    // MARK: 段と拾う

    private func swatch(_ c: SIMD3<Double>) -> CIImage {
        CIImage(color: CIColor(red: c.x, green: c.y, blue: c.z, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))
    }

    func testStageAppliesCubeAndSamplerReadsIt() {
        let picked = ColorSampler.sample(swatch(palePink), at: CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(picked.hue, M.lch(M.oklab(palePink)).h, accuracy: 1.5)
        XCTAssertFalse(picked.isNearlyGray)
        XCTAssertTrue(ColorSampler.sample(swatch(white), at: CGPoint(x: 0.5, y: 0.5)).isNearlyGray)

        var settings = DevelopSettings()
        var p = ColorPointAdjust.picked(hue: picked.hue, chroma: picked.chroma, lightness: picked.lightness)
        p.add = 60
        settings.colorAdjust = ColorAdjustSettings(points: [p])
        let out = ColorAdjustStage().apply(swatch(palePink), settings: settings, options: RenderOptions())
        let after = ColorSampler.sample(out, at: CGPoint(x: 0.5, y: 0.5))
        XCTAssertGreaterThan(after.chroma, picked.chroma + 5, "段を通すとピンク味が増す")
        let whiteOut = ColorSampler.sample(ColorAdjustStage().apply(swatch(white), settings: settings, options: RenderOptions()),
                                           at: CGPoint(x: 0.5, y: 0.5))
        XCTAssertLessThan(whiteOut.chroma, 2, "白は白のまま")
    }

    /// LUT を作る時間(大きさを決めるために測る。デバッグビルドの値)
    func testCubeBuildTime() {
        let s = ColorAdjustSettings(bands: [.orange: ColorBandAdjust(hue: 20, saturation: 30, luminance: 10)],
                                    points: (0..<3).map { ColorPointAdjust(hue: Double($0) * 100, chroma: 20, add: 30) })
        for n in [33, 64] {
            let start = Date()
            let data = ColorCubeLook.makeCube(size: n) { c in
                let o = M.apply(s, to: SIMD3<Double>(Double(c.x), Double(c.y), Double(c.z)))
                return SIMD3<Float>(Float(o.x), Float(o.y), Float(o.z))
            }
            print("色別補正の LUT \(n)³: \(Int(Date().timeIntervalSince(start) * 1000))ms(\(data.count / 1024) KB)")
        }
    }
}
