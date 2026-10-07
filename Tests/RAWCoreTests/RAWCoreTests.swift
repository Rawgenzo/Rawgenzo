import XCTest
import CoreImage
@testable import RAWCore

final class CameraTests: XCTestCase {
    func testSonyA7S3Matches() {
        let p = SonyA7S3Profile()
        XCTAssertTrue(p.matches(RAWMetadata(make: "SONY", model: "ILCE-7SM3")))
        XCTAssertFalse(p.matches(RAWMetadata(make: "SONY", model: "ILCE-7M4")))
        XCTAssertFalse(p.matches(RAWMetadata(make: "Canon", model: "ILCE-7SM3")))
    }

    func testRegistryPicksProfile() {
        let registry = CameraRegistry.makeDefault()
        XCTAssertEqual(registry.profile(for: RAWMetadata(make: "SONY", model: "ILCE-7SM3"))?.id,
                       "sony.ilce-7sm3")
        XCTAssertNil(registry.profile(for: RAWMetadata(make: "NIKON", model: "Z 8")))
        XCTAssertTrue(registry.isCandidate(URL(fileURLWithPath: "/a/DSC0001.ARW")))
    }

    /// 高感度の輝度ノイズ除去はデコーダが ISO に応じて決める(DetailTests で実サンプルを確認)ので、
    /// プロファイルでは初期値を入れない
    func testNoiseReductionIsLeftToDecoder() {
        let p = SonyA7S3Profile()
        XCTAssertNil(p.initialSettings(for: RAWMetadata(iso: 640)).luminanceNoiseReduction)
        XCTAssertNil(p.initialSettings(for: RAWMetadata(iso: 25600)).luminanceNoiseReduction)
    }
}

final class SettingsTests: XCTestCase {
    func testRoundTrip() throws {
        var s = DevelopSettings()
        s.exposure = 0.7
        s.hdr.strength = 0.5
        s.crop = CropSettings(x: 0.1, y: 0.2, width: 0.5, height: 0.4, angle: 2, aspect: .r3x2)
        s.look = LookSelection(id: "builtin.film", strength: 0.6)
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(DevelopSettings.self, from: data), s)
    }

    func testOldSidecarWithMissingKeysStillLoads() throws {
        let json = #"{"exposure": 1.5}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(DevelopSettings.self, from: json)
        XCTAssertEqual(s.exposure, 1.5)
        XCTAssertEqual(s.saturation, 1.0)
        XCTAssertNil(s.crop)
    }

    /// 旧形式(schemaVersion 1)の lensCorrection(Bool)は読み捨て、レンズ補正はカメラ設定に従う(lens = nil)
    func testSchema1LensCorrectionIsIgnored() throws {
        let json = #"{"schemaVersion": 1, "exposure": 0.5, "lensCorrection": true}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(DevelopSettings.self, from: json)
        XCTAssertEqual(s.exposure, 0.5)
        XCTAssertNil(s.lens)
        // 新形式は書いて読める。指定が無ければ書かない
        var t = DevelopSettings()
        XCTAssertFalse(String(data: try JSONEncoder().encode(t), encoding: .utf8)!.contains("\"lens\""))
        t.lens = LensCorrectionSettings(vignetting: true, distortion: false, chromaticAberration: true)
        let u = try JSONDecoder().decode(DevelopSettings.self, from: JSONEncoder().encode(t))
        XCTAssertEqual(u.lens, t.lens)
        XCTAssertEqual(u.schemaVersion, DevelopSettings.currentSchemaVersion)
        // 項目が欠けていれば「掛ける」、型が違っていても全体の読み込みは失敗しない
        let partial = #"{"lens": {"distortion": false}}"#.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(DevelopSettings.self, from: partial).lens,
                       LensCorrectionSettings(vignetting: true, distortion: false, chromaticAberration: true))
        let broken = #"{"exposure": 1, "lens": true}"#.data(using: .utf8)!
        let b = try JSONDecoder().decode(DevelopSettings.self, from: broken)
        XCTAssertEqual(b.exposure, 1)
        XCTAssertNil(b.lens)
    }

    func testCenteredCropKeepsRatio() {
        // 3:2 の画像を 1:1 で切ると、幅は高さの 2/3
        let c = CropSettings.centered(aspect: .square, imageAspect: 1.5)
        XCTAssertEqual(c.height, 1, accuracy: 1e-9)
        XCTAssertEqual(c.width, 2.0 / 3, accuracy: 1e-9)
        XCTAssertEqual(c.x, (1 - 2.0 / 3) / 2, accuracy: 1e-9)
    }
}

final class StageTests: XCTestCase {
    private let image = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 300, height: 200))

    func testCropProducesExpectedSize() {
        var s = DevelopSettings()
        s.crop = CropSettings(x: 0.5, y: 0, width: 0.5, height: 0.5)
        let out = CropStage().apply(image, settings: s, options: RenderOptions())
        XCTAssertEqual(out.extent, CGRect(x: 0, y: 0, width: 150, height: 100))
    }

    func testCropTopLeftMapsToCoreImageTop() {
        // 左上原点の (0,0,0.5,0.5) は Core Image(左下原点) では上半分
        let r = CropStage.pixelRect(for: CropSettings(x: 0, y: 0, width: 0.5, height: 0.5),
                                    in: CGRect(x: 0, y: 0, width: 300, height: 200))
        XCTAssertEqual(r, CGRect(x: 0, y: 100, width: 150, height: 100))
    }

    func testRotateOnlyKeepsFrame() {
        var s = DevelopSettings()
        s.crop = CropSettings(x: 0.2, y: 0.2, width: 0.3, height: 0.3, angle: 5)
        let out = CropStage().apply(image, settings: s, options: RenderOptions(cropMode: .rotateOnly))
        XCTAssertEqual(out.extent, image.extent)
    }

    func testStagesRunInPhaseOrder() {
        let looks = LookRegistry(looks: [])
        let phases = DevelopPipeline.makeDefault(looks: looks).stages.map(\.phase)
        XCTAssertEqual(phases, phases.sorted())
    }
}

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

final class LensCorrectionTests: XCTestCase {
    /// DSC03451(FE 16-35mm GM、16mm F2.8)の値(exiftool で確認したもの)
    private let d16 = [16, 27, 0, -38, -83, -138, -201, -275, -349, -426, -492, -555, -604, -645, -670, -683, -679]
    private let v16 = [16, 0, 64, 192, 416, 736, 1152, 1664, 2208, 2912, 3872, 4992, 6304, 7712, 9152, 10560, 11904]
    private let c16 = [32, 0, 0, 0, 0, 0, 0, 0, 128, 256, 384, 512, 640, 640, 640, 640, 768,
                       896, 896, 896, 896, 896, 640, 512, 512, 384, 384, 256, 256, 256, 256, 384, 512]

    private func data16(camera: LensCorrectionSettings = .all) throws -> LensCorrectionData {
        try XCTUnwrap(LensCorrectionData.sony(distortion: d16, chromatic: c16, vignetting: v16, cameraSettings: camera))
    }

    func testSonyConversion() throws {
        let l = try data16()
        XCTAssertEqual(l.knots.count, 16)
        XCTAssertEqual(l.knots[0], 0.5 / 15, accuracy: 1e-12)
        XCTAssertEqual(l.knots[15], 15.5 / 15, accuracy: 1e-12)
        XCTAssertEqual(l.distortion[15], 1 - 679.0 / 16384, accuracy: 1e-12)     // 約 0.9586(樽型の補正)
        XCTAssertEqual(l.chromaticRed[15], 1 + 768.0 / 2_097_152, accuracy: 1e-12)   // R の 16 個目 = 配列の 16 番目
        XCTAssertEqual(l.chromaticBlue[15], 1 + 512.0 / 2_097_152, accuracy: 1e-12)
        // 周辺減光: 値 0 なら補正なし、外周(11904)では約 +0.87 EV
        XCTAssertEqual(l.vignetting[0], 1, accuracy: 1e-12)
        XCTAssertEqual(-log2(l.vignetting[15]), 0.869, accuracy: 0.001)
    }

    func testSonyRejectsMalformedData() {
        XCTAssertNil(LensCorrectionData.sony(distortion: [16, 1, 2], chromatic: c16, vignetting: v16, cameraSettings: .all))
        XCTAssertNil(LensCorrectionData.sony(distortion: d16, chromatic: [16] + c16.dropFirst(), vignetting: v16, cameraSettings: .all))
        XCTAssertNil(LensCorrectionData.sony(distortion: [17] + d16.dropFirst(), chromatic: c16, vignetting: v16, cameraSettings: .all))
        XCTAssertNil(LensCorrectionData.sony(distortion: [], chromatic: c16, vignetting: v16, cameraSettings: .all))
    }

    func testInterpolationClampsAtEnds() throws {
        let l = try data16()
        XCTAssertEqual(LensCorrectionData.interpolate(l.knots, l.distortion, at: 0), l.distortion[0])
        XCTAssertEqual(LensCorrectionData.interpolate(l.knots, l.distortion, at: 2), l.distortion[15])
        let mid = (l.knots[3] + l.knots[4]) / 2
        XCTAssertEqual(LensCorrectionData.interpolate(l.knots, l.distortion, at: mid),
                       (l.distortion[3] + l.distortion[4]) / 2, accuracy: 1e-12)
    }

    func testSettingsTurnCorrectionsOff() throws {
        let l = try data16()
        XCTAssertEqual(l.magnification(.green, at: 0.9, settings: .off), 1)
        XCTAssertEqual(l.magnification(.red, at: 0.9, settings: .off), 1)
        XCTAssertEqual(l.vignettingFactor(at: 0.9, settings: .off), 1)
        let caOnly = LensCorrectionSettings(vignetting: false, distortion: false, chromaticAberration: true)
        XCTAssertEqual(l.magnification(.green, at: 0.9, settings: caOnly), 1)
        XCTAssertGreaterThan(l.magnification(.red, at: 0.9, settings: caOnly), 1)
    }

    /// 糸巻き型(外側の倍率 > 1)なら、縁が画像の内側から色を取れる最小の拡大率になる。樽型なら拡大しない
    func testAutoScale() throws {
        let barrel = try data16()
        XCTAssertEqual(barrel.autoScale(settings: LensCorrectionSettings(vignetting: true, distortion: true, chromaticAberration: false),
                                        imageAspect: 1.5), 1)
        // DSC03561(FE 50mm GM、50mm)の歪曲は外側で正(糸巻き型)
        let d50 = [16, 4, 2, -2, -4, -9, -13, -18, -18, -20, -13, -2, 22, 61, 124, 216, 350]
        let pin = try XCTUnwrap(LensCorrectionData.sony(distortion: d50, chromatic: c16, vignetting: v16, cameraSettings: .all))
        let s = pin.autoScale(settings: .all, imageAspect: 1.5)
        XCTAssertGreaterThan(s, 1)
        XCTAssertLessThan(s, 1.03)
        // s なら縁のどの点も内側から取れ、少し小さいとはみ出す
        let d = (1.5 * 1.5 + 1).squareRoot()
        let hw = 1.5 / d, hh = 1 / d
        func worst(_ scale: Double) -> Double {
            var m = 0.0
            for i in 0...200 {
                let t = Double(i) / 200
                for p in [SIMD2(hw, hh * t), SIMD2(hw * t, hh)] {
                    for c in LensCorrectionData.Channel.allCases {
                        let q = pin.sourcePoint(p, channel: c, settings: .all, scale: scale)
                        m = max(m, abs(q.x) / hw, abs(q.y) / hh)
                    }
                }
            }
            return m
        }
        XCTAssertLessThanOrEqual(worst(s), 1 + 1e-9)
        XCTAssertGreaterThan(worst(s * 0.999), 1)
    }

    /// 手で作った TIFF(ビッグエンディアン、SubIFD に補正タグ)を読める
    func testTIFFReaderReadsSubIFD() throws {
        var b = Data()
        func u16(_ v: Int) { b.append(UInt8(v >> 8 & 0xff)); b.append(UInt8(v & 0xff)) }
        func u32(_ v: Int) { u16(v >> 16); u16(v & 0xffff) }
        b.append(contentsOf: [0x4D, 0x4D]); u16(42); u32(8)
        // IFD0(位置 8): SubIFDs → 26
        u16(1); u16(0x014a); u16(4); u32(1); u32(26); u32(0)
        // SubIFD(位置 26): 0x7036 = 1(値は項目の中)、0x7037 = SSHORT 3 個(位置 56 に)。番号順に並べない
        u16(2)
        u16(0x7037); u16(8); u32(3); u32(56)
        u16(0x7036); u16(3); u32(1); u16(1); u16(0)
        u32(0)
        XCTAssertEqual(b.count, 56)
        u16(2); u16(0xFFFE); u16(7)   // 2, -2, 7
        let t = try XCTUnwrap(TIFFReader(data: b))
        let ifd0 = try XCTUnwrap(t.entries(atIFD: try XCTUnwrap(t.firstIFDOffset)))
        let sub = try XCTUnwrap(t.integers(try XCTUnwrap(ifd0.first { $0.tag == 0x014a })))
        let entries = try XCTUnwrap(t.entries(atIFD: sub[0]))
        XCTAssertEqual(entries.first { $0.tag == 0x7037 }.flatMap(t.integers), [2, -2, 7])
        XCTAssertEqual(entries.first { $0.tag == 0x7036 }.flatMap(t.integers), [1])
        // 範囲外を指していても落ちない
        XCTAssertNil(t.entries(atIFD: 10_000))
        XCTAssertNil(TIFFReader(data: Data([0x49, 0x49, 0, 0])))
    }

    /// 実際の ARW から読んだ値が exiftool の値と一致する(RAW_SAMPLE_DIR を指定したときだけ)
    func testReadsSampleARW() throws {
        guard let dir = ProcessInfo.processInfo.environment["RAW_SAMPLE_DIR"] else {
            throw XCTSkip("RAW_SAMPLE_DIR が未設定")
        }
        let url = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath).appendingPathComponent("DSC03451.ARW")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("DSC03451.ARW がありません") }
        let tags = try XCTUnwrap(SonyLensCorrection.readTags(from: url))
        XCTAssertEqual(tags.distortionParams, d16)
        XCTAssertEqual(tags.vignettingParams, v16)
        XCTAssertEqual(tags.chromaticParams, c16)
        XCTAssertEqual(tags.vignettingSetting, 257)   // オート
        XCTAssertEqual(tags.chromaticSetting, 1)      // オート
        XCTAssertEqual(tags.distortionSetting, 0)     // 切
        let photo = try RAWEngine().open(url)
        let lens = try XCTUnwrap(photo.lensCorrection)
        XCTAssertEqual(lens.cameraSettings, LensCorrectionSettings(vignetting: true, distortion: false, chromaticAberration: true))
        XCTAssertEqual(lens, try data16(camera: lens.cameraSettings))
    }
}

/// GPU のカーネルが CPU の計算(LensCorrectionData.sourcePoint)と同じ位置から色を取ること
final class LensCorrectorRenderTests: XCTestCase {
    private let w = 600.0, h = 400.0
    private let ctx = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    /// R = x / 幅、G = y / 高さ(Core Image の座標、画素の中心)を持つ画像。色から元の位置が分かる
    private func coordinateImage() -> CIImage {
        let wi = Int(w), hi = Int(h)
        var px = [Float](repeating: 1, count: wi * hi * 4)
        for row in 0..<hi {
            let y = Double(hi - 1 - row)   // ビットマップの 1 行目は上端
            for x in 0..<wi {
                let i = (row * wi + x) * 4
                px[i] = Float((Double(x) + 0.5) / w)
                px[i + 1] = Float((y + 0.5) / h)
                px[i + 2] = 0
            }
        }
        let data = px.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: data, bytesPerRow: wi * 16, size: CGSize(width: w, height: h),
                       format: .RGBAf, colorSpace: nil)
    }

    private func pixel(_ image: CIImage, _ x: Int, _ y: Int) -> [Float] {
        var px = [Float](repeating: 0, count: 4)
        ctx.render(image, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: x, y: y, width: 1, height: 1),
                   format: .RGBAf, colorSpace: nil)
        return px
    }

    /// 強めの樽型 + 倍率色収差(周辺減光なし)の補正データ
    private func strongData() -> LensCorrectionData {
        let n = 16
        let knots = (0..<n).map { (Double($0) + 0.5) / Double(n - 1) }
        return LensCorrectionData(knots: knots,
                                  distortion: knots.map { 1 - 0.06 * $0 * $0 },
                                  chromaticRed: knots.map { 1 + 0.004 * $0 },
                                  chromaticBlue: knots.map { 1 - 0.004 * $0 },
                                  vignetting: knots.map { _ in 1 },
                                  cameraSettings: .all)
    }

    func testCoordinateImageEncodesPosition() {
        let img = coordinateImage()
        let p = pixel(img, 150, 300)
        XCTAssertEqual(Double(p[0]) * w, 150.5, accuracy: 0.6)
        XCTAssertEqual(Double(p[1]) * h, 300.5, accuracy: 0.6)
    }

    func testGPUMatchesCPU() throws {
        let data = strongData()
        let settings = LensCorrectionSettings(vignetting: false, distortion: true, chromaticAberration: true)
        let out = try LensCorrector.apply(coordinateImage(), data: data, settings: settings)
        XCTAssertEqual(out.extent, CGRect(x: 0, y: 0, width: w, height: h))
        let scale = data.autoScale(settings: settings, imageAspect: w / h)
        let halfDiag = (w * w + h * h).squareRoot() / 2
        // 画像全体を一度に描いたときと、一部だけ描いたとき(入出力の範囲がずれる)の両方を調べる
        for (x, y) in [(30, 20), (300, 200), (570, 380), (80, 350), (500, 60), (299, 5)] {
            let px = pixel(out, x, y)
            let p = SIMD2(Double(x) + 0.5 - w / 2, Double(y) + 0.5 - h / 2) / halfDiag
            let red = data.sourcePoint(p, channel: .red, settings: settings, scale: scale) * halfDiag + SIMD2(w / 2, h / 2)
            let green = data.sourcePoint(p, channel: .green, settings: settings, scale: scale) * halfDiag + SIMD2(w / 2, h / 2)
            XCTAssertEqual(Double(px[0]) * w, red.x, accuracy: 0.6, "R の x (\(x), \(y))")
            XCTAssertEqual(Double(px[1]) * h, green.y, accuracy: 0.6, "G の y (\(x), \(y))")
        }
        // 全体を一度に描いた結果とも一致する
        var whole = [Float](repeating: 0, count: Int(w * h) * 4)
        ctx.render(out, toBitmap: &whole, rowBytes: Int(w) * 16, bounds: out.extent, format: .RGBAf, colorSpace: nil)
        for (x, y) in [(30, 20), (570, 380), (80, 350)] {
            let row = Int(h) - 1 - y   // ビットマップの 1 行目は上端
            let i = (row * Int(w) + x) * 4
            let px = pixel(out, x, y)
            XCTAssertEqual(whole[i], px[0], accuracy: 1e-3)
            XCTAssertEqual(whole[i + 1], px[1], accuracy: 1e-3)
        }
    }

    func testVignettingBrightensCorners() throws {
        let n = 16
        let knots = (0..<n).map { (Double($0) + 0.5) / Double(n - 1) }
        // 外側ほど暗いレンズ: k = 1 − 0.5 r²(隅で半分の明るさ → 2 倍に明るくする)
        let data = LensCorrectionData(knots: knots, distortion: knots.map { _ in 1 },
                                      chromaticRed: knots.map { _ in 1 }, chromaticBlue: knots.map { _ in 1 },
                                      vignetting: knots.map { 1 - 0.5 * $0 * $0 }, cameraSettings: .all)
        let gray = CIImage(color: CIColor(red: 0.25, green: 0.25, blue: 0.25)).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        let out = try LensCorrector.apply(gray, data: data, settings: .all)
        let halfDiag = (w * w + h * h).squareRoot() / 2
        for (x, y) in [(300, 200), (10, 10), (590, 200), (300, 395)] {
            let d = SIMD2(Double(x) + 0.5 - w / 2, Double(y) + 0.5 - h / 2)
            let r = (d * d).sum().squareRoot() / halfDiag
            let k = LensCorrectionData.interpolate(knots, data.vignetting, at: r)
            XCTAssertEqual(Double(pixel(out, x, y)[1]), 0.25 / k, accuracy: 0.002, "(\(x), \(y))")
        }
        // 全部切れば元の画像そのもの
        XCTAssertTrue(try LensCorrector.apply(gray, data: data, settings: .off) === gray)
    }

    /// 実際の ARW: 周辺減光の補正で隅が中心に比べて明るくなる。切れば補正前と同じ(RAW_SAMPLE_DIR のときだけ)
    func testSampleVignetting() throws {
        guard let dir = ProcessInfo.processInfo.environment["RAW_SAMPLE_DIR"] else { throw XCTSkip("RAW_SAMPLE_DIR が未設定") }
        let url = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath).appendingPathComponent("DSC03451.ARW")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("DSC03451.ARW がありません") }
        let engine = RAWEngine()
        let photo = try engine.open(url)
        var s = DevelopSettings()
        func cornerToCenter(_ lens: LensCorrectionSettings) throws -> Double {
            s.lens = lens
            let img = try engine.pipeline.process(photo, settings: s, options: RenderOptions(scale: 0.25))
            let e = img.extent
            func mean(_ r: CGRect) -> Double {
                let avg = img.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: r)])
                var px = [Float](repeating: 0, count: 4)
                ctx.render(avg, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: nil)
                return Double(px[2])   // 空の写真なので青で見る
            }
            let corner = mean(CGRect(x: e.minX + 5, y: e.maxY - 45, width: 40, height: 40))     // 左上(空)
            let center = mean(CGRect(x: e.midX - 20, y: e.maxY - e.height * 0.3, width: 40, height: 40))
            return corner / center
        }
        let before = try cornerToCenter(.off)
        let after = try cornerToCenter(LensCorrectionSettings(vignetting: true, distortion: false, chromaticAberration: false))
        // 16mm F2.8 の隅は約 +0.9 EV 補正される。隅と中心の比が大きく上がる
        XCTAssertGreaterThan(after / before, 1.4)
    }
}

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

/// デコーダのシャープネス・色ノイズ除去が、このアプリの処理を通して効くこと(RAW_SAMPLE_DIR のときだけ)
final class DetailTests: XCTestCase {
    private let ctx = CIContext(options: [.workingColorSpace: NSNull()])

    /// 中央 300×300 の、隣の画素との明るさの差(細かい凹凸)と色の差(色のばらつき)の平均
    private func measure(_ img: CIImage) -> (luma: Double, chroma: Double) {
        let e = img.extent
        let n = 300
        let r = CGRect(x: (e.midX - 150).rounded(), y: (e.midY - 150).rounded(), width: CGFloat(n), height: CGFloat(n))
        var b = [Float](repeating: 0, count: n * n * 4)
        ctx.render(img, toBitmap: &b, rowBytes: n * 16, bounds: r, format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        var luma = 0.0, chroma = 0.0
        for y in 0..<n { for x in 0..<(n - 1) {
            let i = (y * n + x) * 4, j = i + 4
            func Y(_ p: Int) -> Double { 0.2126 * Double(b[p]) + 0.7152 * Double(b[p + 1]) + 0.0722 * Double(b[p + 2]) }
            luma += abs(Y(i) - Y(j))
            chroma += abs((Double(b[i]) - Y(i)) - (Double(b[j]) - Y(j))) + abs((Double(b[i + 2]) - Y(i)) - (Double(b[j + 2]) - Y(j)))
        } }
        let count = Double(n * (n - 1))
        return (luma / count, chroma / count)
    }

    private func open(_ name: String) throws -> (RAWEngine, Photo) {
        guard let dir = ProcessInfo.processInfo.environment["RAW_SAMPLE_DIR"] else { throw XCTSkip("RAW_SAMPLE_DIR が未設定") }
        let url = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath).appendingPathComponent("\(name).ARW")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("\(name).ARW がありません") }
        let engine = RAWEngine()
        return (engine, try engine.open(url))
    }

    func testDecoderDefaults() throws {
        let (_, photo) = try open("DSC03561")
        XCTAssertEqual(photo.source.detailDefaults, DetailDefaults(sharpness: 1, luminanceNoiseReduction: 0, colorNoiseReduction: 0.5))
    }

    func testSharpnessWorksOnlyAtFullResolution() throws {
        let (engine, photo) = try open("DSC03561")
        func detail(_ v: Double, scale: Double) throws -> Double {
            var s = DevelopSettings()
            s.sharpness = v
            return measure(try engine.pipeline.process(photo, settings: s, options: RenderOptions(scale: scale))).luma
        }
        // 等倍: 0 < 既定(1) < 3
        let a = try detail(0, scale: 1), b = try detail(1, scale: 1), c = try detail(3, scale: 1)
        XCTAssertGreaterThan(b, a * 1.1)
        XCTAssertGreaterThan(c, b * 1.1)
        // 縮小して描くと効かない(デコーダの仕様。UI に注記している)
        XCTAssertEqual(try detail(0, scale: 0.5), try detail(3, scale: 0.5), accuracy: 1e-6)
    }

    /// 高感度(ISO 8000)の写真: 輝度ノイズ除去が効く。既定値は ISO に応じたデコーダの値。1 を超えた値は 1 に丸める
    func testLuminanceNoiseReductionAtHighISO() throws {
        let (engine, photo) = try open("DSC03402")
        XCTAssertEqual(photo.source.detailDefaults.luminanceNoiseReduction, 0.302, accuracy: 0.01)
        // 初期値はデコーダに任せる(photo.settings はサイドカーがあればその値なので、プロファイルの初期値で確かめる)
        XCTAssertNil(photo.profile.initialSettings(for: photo.metadata).luminanceNoiseReduction)
        func detail(_ v: Double?) throws -> Double {
            var s = DevelopSettings()
            s.luminanceNoiseReduction = v
            return measure(try engine.pipeline.process(photo, settings: s, options: RenderOptions(scale: 1))).luma
        }
        let off = try detail(0), def = try detail(nil), full = try detail(1)
        XCTAssertGreaterThan(off, def * 1.05)
        XCTAssertGreaterThan(def, full * 1.2)
        XCTAssertEqual(try detail(2), full, accuracy: 1e-9)   // 1 を超えると逆に効くので丸める
        XCTAssertEqual(DetailRanges.luminanceNoiseReduction.upperBound, 1)
    }

    func testColorNoiseReduction() throws {
        let (engine, photo) = try open("DSC03451")
        func chroma(_ v: Double?) throws -> Double {
            var s = DevelopSettings()
            s.colorNoiseReduction = v
            return measure(try engine.pipeline.process(photo, settings: s, options: RenderOptions(scale: 1))).chroma
        }
        let off = try chroma(0), def = try chroma(nil), half = try chroma(0.5)
        XCTAssertGreaterThan(off, def * 1.5)
        XCTAssertEqual(def, half, accuracy: 1e-9)   // nil = デコーダ既定値(0.5)
    }
}

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

final class CompositionGuideTests: XCTestCase {
    func testRatioPositions() {
        XCTAssertEqual(CompositionGuides.golden.positions[1], 0.618, accuracy: 0.001)
        XCTAssertEqual(CompositionGuides.silver.positions[0], 0.414, accuracy: 0.001)
        // 縦線と横線が1本ずつ × 分割位置の数
        XCTAssertEqual(CompositionGuides.thirds.paths(aspect: 1.5, options: GuideOptions()).count, 4)
        XCTAssertEqual(CompositionGuides.halves.paths(aspect: 1.5, options: GuideOptions()).count, 2)
    }

    func testSpiralStaysInsideAndIsContinuous() {
        let paths = CompositionGuides.spiral.paths(aspect: 1.5, options: GuideOptions())
        let spiral = paths.last!.points
        for p in spiral {
            XCTAssert((-1e-9...1 + 1e-9).contains(Double(p.x)) && (-1e-9...1 + 1e-9).contains(Double(p.y)))
        }
        for (a, b) in zip(spiral, spiral.dropFirst()) {
            XCTAssertLessThan(hypot(a.x - b.x, a.y - b.y), 0.08, "螺旋が途切れています")
        }
    }

    func testFlipsMoveTheEyeToEachCorner() {
        let g = CompositionGuides.spiral
        let eye = g.eye(aspect: 1.5, options: GuideOptions())
        XCTAssertGreaterThan(eye.x, 0.5); XCTAssertGreaterThan(eye.y, 0.5)       // 右下
        let h = g.eye(aspect: 1.5, options: GuideOptions(flipHorizontal: true))
        XCTAssertLessThan(h.x, 0.5); XCTAssertGreaterThan(h.y, 0.5)              // 左下
        let v = g.eye(aspect: 1.5, options: GuideOptions(flipVertical: true))
        XCTAssertGreaterThan(v.x, 0.5); XCTAssertLessThan(v.y, 0.5)              // 右上
    }

    func testDiagonalConnectsCorners() {
        let paths = CompositionGuides.diagonal.paths(aspect: 1.5, options: GuideOptions())
        XCTAssertEqual(paths.count, 2)
        XCTAssertEqual(paths[0].points, [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)])
    }

    func testGoldenTrianglePerpendicularsOnScreen() {
        let aspect = 1.5
        let paths = CompositionGuides.triangle.paths(aspect: aspect, options: GuideOptions())
        XCTAssertEqual(paths.count, 3)
        // 画面上(ピクセル空間)で直角になっていること
        func px(_ p: CGPoint) -> (Double, Double) { (Double(p.x) * aspect, Double(p.y)) }
        let d0 = px(paths[0].points[0]), d1 = px(paths[0].points[1])
        let diag = (d1.0 - d0.0, d1.1 - d0.1)
        for perp in paths.dropFirst() {
            let a = px(perp.points[0]), b = px(perp.points[1])
            let dot = (b.0 - a.0) * diag.0 + (b.1 - a.1) * diag.1
            XCTAssertEqual(dot, 0, accuracy: 1e-9)
            // 垂線の足は対角線上にある
            let cross = (b.0 - d0.0) * diag.1 - (b.1 - d0.1) * diag.0
            XCTAssertEqual(cross, 0, accuracy: 1e-9)
        }
    }

    func testGoldenTriangleFlipUsesOtherDiagonal() {
        let paths = CompositionGuides.triangle.paths(aspect: 1.5, options: GuideOptions(flipTriangle: true))
        XCTAssertEqual(paths[0].points[0], CGPoint(x: 1, y: 0))
        XCTAssertEqual(paths[0].points[1], CGPoint(x: 0, y: 1))
    }

    func testGuideIDsAreUnique() {
        let ids = CompositionGuides.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }
}

final class FileNameTemplateTests: XCTestCase {
    private let ctx: FileNameTemplate.Context = {
        var c = FileNameTemplate.Context.sample
        c.sequence = 7
        return c
    }()

    private func render(_ p: String) throws -> String { try FileNameTemplate(p).render(ctx) }

    func testBasicVariables() throws {
        XCTAssertEqual(try render("{name}"), "DSC01234")
        XCTAssertEqual(try render("{date}_{name}"), "20260914_DSC01234")
        XCTAssertEqual(try render("{date:yyyy-MM-dd}_{seq:3}"), "2026-09-14_007")
        XCTAssertEqual(try render("{model}_ISO{iso}_{name}"), "ILCE-7SM3_ISO12800_DSC01234")
        XCTAssertEqual(try render("F{f}_{shutter}_{focal}mm"), "F2.8_1-250_35mm")
        XCTAssertEqual(try render("{folder}"), "2026-09 Kanazawa")
        XCTAssertEqual(try render("{width}x{height}"), "4240x2832")
    }

    func testEmptyValuesAndUnsafeCharacters() throws {
        var c = ctx
        c.metadata.lensModel = nil
        XCTAssertEqual(try FileNameTemplate("{lens}_{name}").render(c), "DSC01234")   // 端の _ は落とす
        XCTAssertEqual(try render("{date:yyyy/MM/dd}"), "2026-09-14")                // / は使えない
        XCTAssertEqual(try render("..{name}"), "DSC01234")                           // 隠しファイルにしない
        XCTAssertEqual(try render("{{x}}_{name}"), "{x}_DSC01234")
    }

    func testErrors() {
        XCTAssertEqual(FileNameTemplate("{name").validate(), .unclosedBrace)
        XCTAssertEqual(FileNameTemplate("{foo}").validate(), .unknownVariable("foo"))
        XCTAssertEqual(FileNameTemplate("{seq:0}").validate(), .badSequenceDigits("0"))
        XCTAssertNil(FileNameTemplate("{date:yyyy}_{seq:5}").validate())
    }

    func testUsesSequence() {
        XCTAssertTrue(FileNameTemplate("{date}_{seq}").usesSequence)
        XCTAssertFalse(FileNameTemplate("{date}_{name}").usesSequence)
    }
}

final class ExportPreferencesTests: XCTestCase {
    func testDirectoryModes() {
        let raw = URL(fileURLWithPath: "/Photos/trip/DSC0001.ARW")
        var p = ExportPreferences()
        XCTAssertEqual(p.directory(for: raw).path, "/Photos/trip/developed")
        p.subfolder = ""
        XCTAssertEqual(p.directory(for: raw).path, "/Photos/trip")
        p.directoryMode = .fixed
        p.fixedDirectory = "/Exports"
        XCTAssertEqual(p.directory(for: raw).path, "/Exports")
        p.directoryMode = .lastUsed      // まだ前回が無ければRAWの横
        XCTAssertEqual(p.directory(for: raw).path, "/Photos/trip")
    }

    func testConflictAddsNumber() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: dir.appendingPathComponent("a.jpg"))
        try Data().write(to: dir.appendingPathComponent("a-2.jpg"))
        let url = ExportPreferences.resolve(directory: dir, baseName: "a", fileExtension: "jpg", policy: .addNumber)
        XCTAssertEqual(url.lastPathComponent, "a-3.jpg")
        let over = ExportPreferences.resolve(directory: dir, baseName: "a", fileExtension: "jpg", policy: .overwrite)
        XCTAssertEqual(over.lastPathComponent, "a.jpg")
    }

    func testOldOrHandEditedConfigStillLoads() throws {
        let json = #"{"export": {"fileNameTemplate": "{date}_{name}", "directoryMode": "somethingNew"}, "other": 1}"#
        let c = try JSONDecoder().decode(SharedConfig.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(c.export.fileNameTemplate, "{date}_{name}")
        XCTAssertEqual(c.export.directoryMode, .sameAsRAW)   // 未知の値は既定に戻す
        XCTAssertEqual(c.export.quality, 0.92)
    }
}

final class LookTests: XCTestCase {
    func testBuiltInLooksHaveUniqueIDs() {
        let ids = BuiltInLooks.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testIdentityCubeFileParses() throws {
        var text = "TITLE \"Identity\"\nLUT_3D_SIZE 2\n"
        for b in 0..<2 { for g in 0..<2 { for r in 0..<2 { text += "\(r) \(g) \(b)\n" } } }
        let look = try CubeFileLook(text: text, id: "cube:test", fallbackName: "test")
        XCTAssertEqual(look.size, 2)
        XCTAssertEqual(look.displayName, "Identity")
    }

    func testUserLooksAreSortedByNameAfterBuiltIns() throws {
        func cube(_ title: String) throws -> CubeFileLook {
            var text = "TITLE \"\(title)\"\nLUT_3D_SIZE 2\n"
            for b in 0..<2 { for g in 0..<2 { for r in 0..<2 { text += "\(r) \(g) \(b)\n" } } }
            return try CubeFileLook(text: text, id: "cube:\(title)", fallbackName: title)
        }
        let registry = LookRegistry(looks: BuiltInLooks.all)
        for title in ["08_Night", "02_Warm", "10_Extra", "01_Teal", "9_Nine", "b_lower", "A_upper"] {
            registry.register(try cube(title))
        }
        // 組み込みは元の順のまま先頭
        XCTAssertEqual(registry.all.prefix(BuiltInLooks.all.count).map(\.id), BuiltInLooks.all.map(\.id))
        // 数字は数値として比べる(08 < 9 < 10)、大文字小文字は区別しない
        XCTAssertEqual(registry.userLooks.map(\.displayName),
                       ["01_Teal", "02_Warm", "08_Night", "9_Nine", "10_Extra", "A_upper", "b_lower"])
    }

    func testCubeWithWrongCountFails() {
        let text = "LUT_3D_SIZE 2\n0 0 0\n1 1 1\n"
        XCTAssertThrowsError(try CubeFileLook(text: text, id: "x", fallbackName: "x"))
    }

    /// リポジトリ付属の LUT_examples がすべてルックとして読み込めること
    func testBundledLUTExamplesLoad() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("LUT_examples", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "cube" }
        XCTAssertFalse(files.isEmpty, "LUT_examples に .cube がありません")

        let registry = LookRegistry(looks: BuiltInLooks.all)
        let failures = registry.loadCubeFiles(from: dir)
        XCTAssertTrue(failures.isEmpty, failures.map { "\($0.0.lastPathComponent): \($0.1)" }.joined(separator: "\n"))
        XCTAssertEqual(registry.userLooks.count, files.count)
        XCTAssertTrue(registry.userLooks.allSatisfy { $0.id.hasPrefix("cube:") })
    }
}

/// 実際のサンプルRAWを使うテスト。環境変数 RAW_SAMPLE_DIR を指定したときだけ動く。
///   RAW_SAMPLE_DIR=~/Dropbox/git/Rawgenzo/Rawgenzo/RAWsample swift test
final class SampleFileTests: XCTestCase {
    func testDevelopSamples() throws {
        guard let dir = ProcessInfo.processInfo.environment["RAW_SAMPLE_DIR"] else {
            throw XCTSkip("RAW_SAMPLE_DIR が未設定")
        }
        let engine = RAWEngine()
        let urls = try engine.listCandidates(in: URL(fileURLWithPath: (dir as NSString).expandingTildeInPath))
        XCTAssertFalse(urls.isEmpty, "ARWが見つかりません")

        let context = CIContext()
        for url in urls {
            let photo = try engine.open(url)
            XCTAssertEqual(photo.profile.id, "sony.ilce-7sm3")
            var s = photo.settings
            s.hdr.strength = 0.5
            s.saturation = 1.2
            s.crop = .centered(aspect: .r16x9, imageAspect: photo.imageAspect)
            s.look = LookSelection(id: "builtin.film")
            let image = try engine.pipeline.process(photo, settings: s, options: RenderOptions(scale: 0.25))
            XCTAssertNotNil(context.createCGImage(image, from: image.extent), url.lastPathComponent)
            let ratio = image.extent.width / image.extent.height
            XCTAssertEqual(Double(ratio), 16.0 / 9, accuracy: 0.02)
        }
    }

    /// 描画中に別スレッド(アプリでは UI)から nativeSize などを読んでも、描画が失敗しないこと。
    /// nativeSize が CIRAWFilter に毎回問い合わせる実装だったときは、300 回中 171 回「出力が空」で失敗した。
    func testReadingPropertiesWhileRenderingIsSafe() throws {
        guard let dir = ProcessInfo.processInfo.environment["RAW_SAMPLE_DIR"] else {
            throw XCTSkip("RAW_SAMPLE_DIR が未設定")
        }
        let engine = RAWEngine()
        let urls = try engine.listCandidates(in: URL(fileURLWithPath: (dir as NSString).expandingTildeInPath))
        let photo = try engine.open(try XCTUnwrap(urls.first))
        let expected = photo.source.nativeSize

        let lock = NSLock()
        var reading = true
        var mismatches = 0
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            while true {
                lock.lock(); let go = reading; lock.unlock()
                if !go { break }
                if photo.source.nativeSize != expected || photo.imageAspect <= 0 { mismatches += 1 }
                _ = photo.source.detailDefaults
                _ = photo.source.asShot
            }
            done.signal()
        }
        var failures = 0
        for i in 0..<300 {
            var s = photo.settings
            s.exposure = Double(i % 40) / 10 - 2
            s.temperature = 3000 + Double(i % 50) * 100
            s.tint = Double(i % 30) - 15
            do { _ = try photo.source.render(settings: s, scale: 0.25, draft: false) } catch { failures += 1 }
        }
        lock.lock(); reading = false; lock.unlock()
        done.wait()
        XCTAssertEqual(failures, 0)
        XCTAssertEqual(mismatches, 0)
    }
}
