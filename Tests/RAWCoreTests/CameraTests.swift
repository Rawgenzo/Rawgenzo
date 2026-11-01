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
