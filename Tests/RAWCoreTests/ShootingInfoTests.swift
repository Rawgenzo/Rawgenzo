import XCTest
import CoreImage
@testable import RAWCore

/// 撮影情報とフォーカス位置
final class ShootingInfoTests: XCTestCase {
    func testOrientationMapping() {
        let p = CGPoint(x: 0.2, y: 0.1)   // 横長の記録で左上寄り
        XCTAssertEqual(FocusPointMapping.upright(p, orientation: 1), p)
        // 90° 時計回りに回して見る写真: 左上は右上へ
        XCTAssertEqual(FocusPointMapping.upright(CGPoint(x: 0, y: 0), orientation: 6), CGPoint(x: 1, y: 0))
        XCTAssertEqual(FocusPointMapping.upright(CGPoint(x: 1, y: 0), orientation: 6), CGPoint(x: 1, y: 1))
        // 90° 反時計回り: 左上は左下へ
        XCTAssertEqual(FocusPointMapping.upright(CGPoint(x: 0, y: 0), orientation: 8), CGPoint(x: 0, y: 1))
        XCTAssertEqual(FocusPointMapping.upright(p, orientation: 3), CGPoint(x: 0.8, y: 0.9))
    }

    func testCropMapping() throws {
        let a = 1.5
        XCTAssertEqual(FocusPointMapping.displayed(CGPoint(x: 0.3, y: 0.4), crop: nil, imageAspect: a), CGPoint(x: 0.3, y: 0.4))
        // 右半分を切り抜く: x 0.75 は枠の真ん中、x 0.25 は枠の外
        let right = CropSettings(x: 0.5, y: 0, width: 0.5, height: 1)
        let q = try XCTUnwrap(FocusPointMapping.displayed(CGPoint(x: 0.75, y: 0.5), crop: right, imageAspect: a))
        XCTAssertEqual(q.x, 0.5, accuracy: 1e-9); XCTAssertEqual(q.y, 0.5, accuracy: 1e-9)
        XCTAssertNil(FocusPointMapping.displayed(CGPoint(x: 0.25, y: 0.5), crop: right, imageAspect: a))
        // 傾けても、画像の中心は中心のまま。中心から右の点は、時計回りに回すと下へ動く
        let tilted = CropSettings(angle: 10)
        let center = try XCTUnwrap(FocusPointMapping.displayed(CGPoint(x: 0.5, y: 0.5), crop: tilted, imageAspect: a))
        XCTAssertEqual(center.x, 0.5, accuracy: 1e-9); XCTAssertEqual(center.y, 0.5, accuracy: 1e-9)
        let r = try XCTUnwrap(FocusPointMapping.displayed(CGPoint(x: 0.7, y: 0.5), crop: tilted, imageAspect: a))
        XCTAssertGreaterThan(r.y, 0.5)
    }

    func testLabels() {
        XCTAssertEqual(ExifLabels.exposureProgram(3), "絞り優先")
        XCTAssertEqual(ExifLabels.flash(16), "発光なし")
        XCTAssertEqual(ExifLabels.flash(1), "発光")
        XCTAssertEqual(ExifLabels.shutter(1.0 / 250), "1/250")
        XCTAssertNil(ExifLabels.meteringMode(nil))
    }

    /// 実際の ARW からフォーカス位置と撮影情報を読む(RAW_SAMPLE_DIR のときだけ)
    func testReadsFocusPointFromSample() throws {
        guard let dir = ProcessInfo.processInfo.environment["RAW_SAMPLE_DIR"] else { throw XCTSkip("RAW_SAMPLE_DIR が未設定") }
        let url = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath).appendingPathComponent("DSC03356.ARW")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("DSC03356.ARW が無い") }
        let m = try RAWEngine().open(url).metadata
        // ExifTool で確かめた値: FocusLocation 4240 2832 2120 1416(真ん中)、露出補正 +0.3、絞り優先
        let f = try XCTUnwrap(m.focusPoint)
        XCTAssertEqual(f.x, 0.5, accuracy: 1e-3); XCTAssertEqual(f.y, 0.5, accuracy: 1e-3)
        XCTAssertEqual(m.exposureBias ?? 0, 0.3, accuracy: 0.01)
        XCTAssertEqual(ExifLabels.exposureProgram(m.exposureProgram), "絞り優先")
        XCTAssertEqual(m.orientation, 1)
    }
}
