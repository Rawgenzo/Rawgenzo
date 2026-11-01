import XCTest
import CoreImage
@testable import RAWCore

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
