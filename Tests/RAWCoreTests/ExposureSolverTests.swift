import XCTest
import CoreImage
@testable import RAWCore

/// ExposureSolver: 明るさ・白飛びの目標から露出とハイライト回復を探す
final class ExposureSolverTests: XCTestCase {
    /// 露出で明るく・白飛びが増え、ハイライト回復で白飛びが減る(少し暗くなる)単純な模型
    private func model(_ s: DevelopSettings) -> ImageStats {
        let e = s.exposure, h = s.hdr.highlights
        let mean = min(1, 0.3 * pow(2, e * 0.6)) * (1 - 0.15 * h)
        let clip = max(0, 0.04 * pow(2, e) * (1 - 0.9 * h) - 0.01)
        return ImageStats(width: 1, height: 1, meanLuminance: mean, medianLuminance: mean, p01Luminance: 0,
                          p99Luminance: 1, highlightClipping: clip, channelClipping: [clip, clip, clip], shadowClipping: 0,
                          meanRGB: [mean, mean, mean], histogram: [], rgbHistograms: [], grid: [])
    }

    func testReachesMeanLuminance() throws {
        let r = try ExposureSolver.solve(from: DevelopSettings(), target: .init(meanLuminance: 0.45), evaluate: model)
        XCTAssertTrue(r.luminanceMet)
        XCTAssertEqual(r.stats.meanLuminance, 0.45, accuracy: 0.01)
        XCTAssertGreaterThan(r.settings.exposure, 0)
        XCTAssertLessThan(r.evaluations, 20)
    }

    func testUsesHighlightRecoveryForClipping() throws {
        let r = try ExposureSolver.solve(from: DevelopSettings(),
                                         target: .init(meanLuminance: 0.45, maxHighlightClipping: 0.01), evaluate: model)
        XCTAssertTrue(r.luminanceMet, "\(r.notes)")
        XCTAssertTrue(r.clippingMet)
        XCTAssertGreaterThan(r.settings.hdr.highlights, 0)
        XCTAssertLessThanOrEqual(r.stats.highlightClipping, 0.01)
    }

    /// ハイライト回復を使えないときは露出を下げて白飛びの上限を守る(明るさの目標より優先)
    func testLowersExposureWhenRecoveryIsNotAllowed() throws {
        let r = try ExposureSolver.solve(from: DevelopSettings(),
                                         target: .init(meanLuminance: 0.45, maxHighlightClipping: 0.01,
                                                       allowHighlightRecovery: false), evaluate: model)
        XCTAssertTrue(r.clippingMet)
        XCTAssertFalse(r.luminanceMet)
        XCTAssertEqual(r.settings.hdr.highlights, 0)
        XCTAssertFalse(r.notes.isEmpty)
    }

    /// 模型では露出 −3 でも平均輝度は約 0.086 なので、0.05 には下げきれない
    func testUnreachableTargetIsReported() throws {
        let r = try ExposureSolver.solve(from: DevelopSettings(), target: .init(meanLuminance: 0.05), evaluate: model)
        XCTAssertFalse(r.luminanceMet)
        XCTAssertEqual(r.settings.exposure, ExposureSolver.exposureRange.lowerBound)
        XCTAssertTrue(r.notes.first?.contains("目標の明るさより明るい") == true, "\(r.notes)")
    }

    func testAlreadyMetNeedsOneEvaluation() throws {
        var s = DevelopSettings()
        s.exposure = 0
        let r = try ExposureSolver.solve(from: s, target: .init(meanLuminance: 0.3, maxHighlightClipping: 0.05), evaluate: model)
        XCTAssertEqual(r.evaluations, 1)
        XCTAssertEqual(r.settings, s)
    }

    /// 実際の ARW: 前提の単調性と、暗い写真・白飛びの多い写真で目標に届くこと(RAW_SAMPLE_DIR のときだけ)
    func testSamplePhotos() throws {
        guard let dir = ProcessInfo.processInfo.environment["RAW_SAMPLE_DIR"] else { throw XCTSkip("RAW_SAMPLE_DIR が未設定") }
        let engine = RAWEngine()
        let urls = try engine.listCandidates(in: URL(fileURLWithPath: (dir as NSString).expandingTildeInPath))
        XCTAssertFalse(urls.isEmpty)
        for url in urls {
            let photo = try engine.open(url)
            func eval(_ s: DevelopSettings, _ edge: Int = 512) throws -> ImageStats {
                try ImageStats.compute(engine.pipeline.processFitting(photo, settings: s, longEdge: edge))
            }
            // 単調性: 露出で明るく・白飛びが増える。ハイライト回復で白飛びが減る
            var a = DevelopSettings(), b = DevelopSettings(), c = DevelopSettings()
            a.exposure = -1; b.exposure = 0; c.exposure = 1
            let (sa, sb, sc) = (try eval(a), try eval(b), try eval(c))
            XCTAssertLessThan(sa.meanLuminance, sb.meanLuminance, url.lastPathComponent)
            XCTAssertLessThan(sb.meanLuminance, sc.meanLuminance, url.lastPathComponent)
            XCTAssertLessThanOrEqual(sa.highlightClipping, sb.highlightClipping + 1e-4, url.lastPathComponent)
            var h = c
            h.hdr.highlights = 1
            XCTAssertLessThanOrEqual(try eval(h).highlightClipping, sc.highlightClipping + 1e-4, url.lastPathComponent)

            // 目標: 平均輝度 0.45、白飛び 1% 以下。探索は長辺 512、確かめは長辺 1024(get_stats と同じ)
            let r = try ExposureSolver.solve(from: DevelopSettings(),
                                             target: .init(meanLuminance: 0.45, maxHighlightClipping: 0.01),
                                             coarse: { try eval($0) }, fine: { try eval($0, ImageStats.defaultLongEdge) })
            let check = try eval(r.settings, ImageStats.defaultLongEdge)
            XCTAssertEqual(check, r.stats, "結果の統計は get_stats と同じ解像度")
            XCTAssertTrue(r.clippingMet, "\(url.lastPathComponent) \(r.notes)")
            XCTAssertLessThanOrEqual(check.highlightClipping, 0.01, url.lastPathComponent)
            if r.luminanceMet {
                XCTAssertEqual(check.meanLuminance, 0.45, accuracy: 0.02, url.lastPathComponent)
            }
            print(String(format: "  %@: 露出 %+.2f ハイライト回復 %.2f → 平均 %.3f 白飛び %.2f%% (現像 %d 回) %@",
                         url.lastPathComponent, r.settings.exposure, r.settings.hdr.highlights,
                         check.meanLuminance, check.highlightClipping * 100, r.evaluations, r.notes.joined()))
        }
    }
}
