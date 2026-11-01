import XCTest
import CoreImage
@testable import RAWCore

/// ImageStats: AI に画像の代わりに渡す数値の観測
final class ImageStatsTests: XCTestCase {
    private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    private func solid(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ rect: CGRect) -> CIImage {
        CIImage(color: CIColor(red: r, green: g, blue: b, alpha: 1, colorSpace: srgb)!).cropped(to: rect)
    }

    func testUniformGray() throws {
        let s = try ImageStats.compute(solid(0.5, 0.5, 0.5, CGRect(x: 0, y: 0, width: 200, height: 100)))
        XCTAssertEqual(s.width, 200)
        XCTAssertEqual(s.height, 100)
        XCTAssertEqual(s.meanLuminance, 0.5, accuracy: 0.002)
        XCTAssertEqual(s.medianLuminance, 0.5, accuracy: 0.002)
        XCTAssertEqual(s.meanRGB[0], 0.5, accuracy: 0.002)
        XCTAssertEqual(s.highlightClipping, 0)
        XCTAssertEqual(s.shadowClipping, 0)
        XCTAssertEqual(s.histogram.count, ImageStats.histogramBins)
        XCTAssertEqual(s.histogram.reduce(0, +), 1, accuracy: 0.001)
        XCTAssertEqual(s.histogram[16], 1, accuracy: 0.001)   // 0.5 は 32 区間の 17 番目
    }

    /// 上半分が白・下半分が黒(Core Image の座標では y が大きいほうが上)。grid の 1 行目は上端
    func testClippingAndGridOrientation() throws {
        let top = solid(1, 1, 1, CGRect(x: 0, y: 80, width: 160, height: 80))
        let bottom = solid(0, 0, 0, CGRect(x: 0, y: 0, width: 160, height: 80))
        let s = try ImageStats.compute(top.composited(over: bottom))
        XCTAssertEqual(s.highlightClipping, 0.5, accuracy: 0.001)
        XCTAssertEqual(s.shadowClipping, 0.5, accuracy: 0.001)
        XCTAssertEqual(s.grid.count, ImageStats.gridSize)
        XCTAssertEqual(s.grid[0][0][1], 1, accuracy: 0.001, "1 行目は上端(白)")
        XCTAssertEqual(s.grid[7][7][1], 0, accuracy: 0.001, "最後の行は下端(黒)")
        XCTAssertEqual(s.p01Luminance, 0, accuracy: 0.002)
        XCTAssertEqual(s.p99Luminance, 1, accuracy: 0.002)
    }

    /// 左が赤・右が青。列は左から
    func testGridColumnsAndColorBalance() throws {
        let left = solid(0.8, 0.2, 0.2, CGRect(x: 0, y: 0, width: 100, height: 100))
        let right = solid(0.2, 0.2, 0.8, CGRect(x: 100, y: 0, width: 100, height: 100))
        let s = try ImageStats.compute(left.composited(over: right))
        XCTAssertGreaterThan(s.grid[3][0][0], s.grid[3][0][2])
        XCTAssertGreaterThan(s.grid[3][7][2], s.grid[3][7][0])
        XCTAssertEqual(s.meanRGB[0], s.meanRGB[2], accuracy: 0.002)
    }

    func testLargeImageIsDownscaled() throws {
        let s = try ImageStats.compute(solid(0.3, 0.3, 0.3, CGRect(x: 0, y: 0, width: 3000, height: 2000)), maxLongEdge: 300)
        XCTAssertEqual(s.width, 300)
        XCTAssertEqual(s.height, 200)
        XCTAssertEqual(s.meanLuminance, 0.3, accuracy: 0.003)
    }

    /// JSON にしたとき短くなるよう桁を丸めている(AI に渡すトークンを減らすため)
    func testJSONIsCompact() throws {
        let s = try ImageStats.compute(solid(0.123456, 0.5, 0.7, CGRect(x: 0, y: 0, width: 64, height: 64)))
        let json = String(decoding: try JSONEncoder().encode(s), as: UTF8.self)
        XCTAssertFalse(json.contains("0.12345"), json)
        XCTAssertLessThan(json.count, 4000)
    }

    /// 実際の ARW: 縮小現像の大きさ、露出を上げると平均輝度と白飛びが増えること、JPEG が作れること
    func testSamplePhoto() throws {
        guard let dir = ProcessInfo.processInfo.environment["RAW_SAMPLE_DIR"] else { throw XCTSkip("RAW_SAMPLE_DIR が未設定") }
        let engine = RAWEngine()
        let urls = try engine.listCandidates(in: URL(fileURLWithPath: (dir as NSString).expandingTildeInPath))
        let photo = try engine.open(try XCTUnwrap(urls.first))

        var s = DevelopSettings()
        s.crop = .centered(aspect: .square, imageAspect: photo.imageAspect)
        let square = try engine.pipeline.processFitting(photo, settings: s, longEdge: 500)
        XCTAssertLessThanOrEqual(max(square.extent.width, square.extent.height), 500)
        XCTAssertGreaterThan(max(square.extent.width, square.extent.height), 490)
        XCTAssertEqual(Double(square.extent.width / square.extent.height), 1, accuracy: 0.02)

        let base = try ImageStats.compute(engine.pipeline.processFitting(photo, settings: DevelopSettings(), longEdge: 1024))
        var bright = DevelopSettings()
        bright.exposure = 2
        let brighter = try ImageStats.compute(engine.pipeline.processFitting(photo, settings: bright, longEdge: 1024))
        XCTAssertGreaterThan(brighter.meanLuminance, base.meanLuminance + 0.05)
        XCTAssertGreaterThanOrEqual(brighter.highlightClipping, base.highlightClipping)

        let jpeg = try PreviewEncoder.jpeg(square)
        XCTAssertEqual(Array(jpeg.prefix(2)), [0xFF, 0xD8])
        XCTAssertLessThan(jpeg.count, 400_000)
    }
}
