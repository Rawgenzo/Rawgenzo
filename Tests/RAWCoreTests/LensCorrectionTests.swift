import XCTest
import CoreImage
@testable import RAWCore

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
