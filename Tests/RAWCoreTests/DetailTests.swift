import XCTest
import CoreImage
@testable import RAWCore

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
