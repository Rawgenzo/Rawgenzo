import XCTest
import CoreImage
@testable import RAWCore

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
