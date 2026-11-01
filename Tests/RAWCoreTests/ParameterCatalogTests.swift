import XCTest
import CoreImage
@testable import RAWCore

/// ParameterCatalog: スライダー・CLI・AI の道具が共通に使うパラメータの記述
final class ParameterCatalogTests: XCTestCase {
    private let context = ParameterContext(asShot: AsShotValues(temperature: 5100, tint: 7),
                                           detailDefaults: DetailDefaults(sharpness: 1, luminanceNoiseReduction: 0.3,
                                                                          colorNoiseReduction: 0.5))

    func testIDsAreUniqueAndEveryGroupHasParameters() {
        XCTAssertEqual(Set(ParameterCatalog.all.map(\.id)).count, ParameterCatalog.all.count)
        for g in ParameterGroup.allCases {
            XCTAssertFalse(ParameterCatalog.parameters(in: g).isEmpty, g.rawValue)
        }
    }

    /// id はサイドカーの JSON のキー(入れ子は . でつなぐ)と一致する
    func testIDMatchesSidecarJSONKey() throws {
        for p in ParameterCatalog.all {
            var s = DevelopSettings()
            let v = (p.range.lowerBound + p.range.upperBound) / 2 + 0.125
            p.set(v, in: &s)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as? [String: Any])
            var node: Any? = json
            for key in p.id.split(separator: ".") { node = (node as? [String: Any])?[String(key)] }
            XCTAssertEqual(try XCTUnwrap(node as? Double, p.id), v, accuracy: 1e-12, p.id)
            XCTAssertEqual(p.storedValue(s), v, p.id)
        }
    }

    func testSetClampsToRange() {
        for p in ParameterCatalog.all {
            var s = DevelopSettings()
            XCTAssertEqual(p.set(p.range.upperBound + 100, in: &s), p.range.upperBound, p.id)
            XCTAssertEqual(p.value(s, context: context), p.range.upperBound, p.id)
            XCTAssertEqual(p.set(p.range.lowerBound - 100, in: &s), p.range.lowerBound, p.id)
            XCTAssertEqual(p.set(.nan, in: &s), p.range.lowerBound, p.id)
        }
    }

    /// 既定の設定では、どのパラメータも基準値(↶ の戻り先)になっている。リセットすると基準値に戻る
    func testDefaultsAndResetMatchBaseline() {
        for p in ParameterCatalog.all {
            var s = DevelopSettings()
            XCTAssertEqual(p.value(s, context: context), p.baselineValue(in: context), p.id)
            XCTAssertTrue(p.range.contains(p.baselineValue(in: context)), p.id)
            p.set(p.range.upperBound, in: &s)
            p.reset(&s)
            XCTAssertEqual(p.value(s, context: context), p.baselineValue(in: context), p.id)
            XCTAssertEqual(p.storedValue(s) == nil, p.isOptional, p.id)
        }
    }

    func testBaselineComesFromPhoto() {
        XCTAssertEqual(ParameterCatalog["temperature"].baselineValue(in: context), 5100)
        XCTAssertEqual(ParameterCatalog["tint"].baselineValue(in: context), 7)
        XCTAssertEqual(ParameterCatalog["luminanceNoiseReduction"].baselineValue(in: context), 0.3)
        XCTAssertEqual(ParameterCatalog["saturation"].baselineValue(in: context), 1)
    }

    /// 範囲は今までの決まり(デコーダで測って決めた範囲、コントラストのカーブ)と同じ
    func testRangesFollowExistingLimits() {
        XCTAssertEqual(ParameterCatalog["contrast"].range, ContrastCurve.range)
        XCTAssertEqual(ParameterCatalog["sharpness"].range, DetailRanges.sharpness)
        XCTAssertEqual(ParameterCatalog["luminanceNoiseReduction"].range, DetailRanges.luminanceNoiseReduction)
        XCTAssertEqual(ParameterCatalog["colorNoiseReduction"].range, DetailRanges.colorNoiseReduction)
        XCTAssertEqual(ParameterCatalog["exposure"].range, -3...3)
        XCTAssertEqual(ParameterCatalog["temperature"].range, 2000...12000)
    }

    func testFormatted() {
        XCTAssertEqual(ParameterCatalog["exposure"].formatted(0.3), "+0.30 EV")
        XCTAssertEqual(ParameterCatalog["contrast"].formatted(-0.5), "-50")
        XCTAssertEqual(ParameterCatalog["temperature"].formatted(5200), "5200 K")
    }

    /// 説明文に書いた効く向き(色温度を上げると暖色、色かぶりを上げるとマゼンタ寄り)が実際の現像と合う。
    /// AI はこの説明文を頼りに操作するので、実物で確かめておく(RAW_SAMPLE_DIR のときだけ)
    func testWhiteBalanceDirectionsMatchSummary() throws {
        guard let dir = ProcessInfo.processInfo.environment["RAW_SAMPLE_DIR"] else { throw XCTSkip("RAW_SAMPLE_DIR が未設定") }
        let engine = RAWEngine()
        let urls = try engine.listCandidates(in: URL(fileURLWithPath: (dir as NSString).expandingTildeInPath))
        let photo = try engine.open(try XCTUnwrap(urls.first))
        let ctx = CIContext(options: [.workingColorSpace: NSNull()])
        func meanRGB(_ edit: (inout DevelopSettings) -> Void) throws -> (r: Double, g: Double, b: Double) {
            var s = DevelopSettings()
            edit(&s)
            let img = try engine.pipeline.process(photo, settings: s, options: RenderOptions(scale: 0.1))
            let avg = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: img,
                                                                  kCIInputExtentKey: CIVector(cgRect: img.extent)])!.outputImage!
            var px = [Float](repeating: 0, count: 4)
            ctx.render(avg, toBitmap: &px, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            return (Double(px[0]), Double(px[1]), Double(px[2]))
        }
        let cool = try meanRGB { ParameterCatalog["temperature"].set(3500, in: &$0) }
        let warm = try meanRGB { ParameterCatalog["temperature"].set(9000, in: &$0) }
        XCTAssertGreaterThan(warm.r / warm.b, cool.r / cool.b, "色温度を上げると暖色になるはず")
        let green = try meanRGB { ParameterCatalog["tint"].set(-100, in: &$0) }
        let magenta = try meanRGB { ParameterCatalog["tint"].set(100, in: &$0) }
        XCTAssertGreaterThan((magenta.r + magenta.b) / 2 / magenta.g, (green.r + green.b) / 2 / green.g,
                             "色かぶりを上げるとマゼンタ寄りになるはず")
    }
}
