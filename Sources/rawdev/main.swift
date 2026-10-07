import Foundation
import RAWCore

// rawdev: サンプルRAWで現像エンジンを確かめるためのコマンドラインツール

let usage = """
使い方:
  rawdev check                     このMacのCore Imageがα7S IIIに対応しているか確認
  rawdev info <ファイル|フォルダ>...   メタデータとカメラ判定結果を表示
  rawdev looks                     使えるルック(〜風フィルター)の一覧
  rawdev config                    設定ファイル (~/.Rawgenzo/config.json) の書き出し設定を表示
  rawdev name <テンプレート> <ファイル>...  ファイル名テンプレートの結果を表示(書き出さない)
  rawdev develop <ファイル|フォルダ>... [オプション]

develop のオプション:
  --out <フォルダ>         出力先 (既定: 設定の保存先。未設定ならRAWと同じフォルダの developed/)
  --name <テンプレート>    出力ファイル名 例: "{date}_{name}" (既定: 設定のテンプレート)
  --seq-start <番号>       {seq} の開始番号 (既定: 1。CLIは設定の連番を進めない)
  --format <形式>          jpeg | heif | tiff16 | heif-hdr (既定: 設定の形式)
  --exposure <EV>          露出補正 例: 0.7
  --contrast <値>          コントラスト -1.2...1.2 (0 = そのまま。アプリの -120...+120 に当たる)
  --sharpness <値>         シャープネス 0...6 (既定 1。等倍で描くときだけ効く)
  --luma-nr <値>           輝度ノイズ除去 0...1 (既定は ISO に応じてデコーダが決める)
  --color-nr <値>          色ノイズ除去 0...2 (既定 0.5)
  --saturation <倍率>      彩度 例: 1.2 (1 = そのまま)
  --vibrance <値>          自然な彩度 -1...1
  --hdr <強さ>             HDR風トーン 0...1
  --highlights <値>        ハイライト回復 0...1
  --shadows <値>           シャドウ持ち上げ 0...1
  --hdr-output             HDR出力 (heif-hdr と組み合わせる)
  --crop <x,y,w,h>         比率で切り抜き 例: 0.1,0.1,0.8,0.8
  --aspect <比率>          中央で切り抜き 例: 16x9, 1x1, 4x5
  --lens <指定>            レンズ補正 camera(撮影時のカメラ設定) | all | off | v,d,ca の組み合わせ
                           (v = 周辺減光, d = 歪曲, ca = 倍率色収差。例: v,ca)
  --angle <度>             傾き補正 (正 = 時計回り。枠は回転後の画像に収まるよう縮める)
  --look <id>              ルック (rawdev looks で確認)
  --look-strength <値>     ルックの強さ 0...1
  --scale <倍率>           縮小して書き出し 例: 0.5
  --save                   この設定をサイドカーに保存
"""

let engine = RAWEngine()
var arguments = Array(CommandLine.arguments.dropFirst())

guard let command = arguments.first else {
    print(usage)
    exit(1)
}
arguments.removeFirst()

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

/// パスを展開(フォルダなら中の候補RAW)
func expand(_ paths: [String]) -> [URL] {
    paths.flatMap { path -> [URL] in
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            print("見つかりません: \(path)")
            return []
        }
        return isDir.boolValue ? ((try? engine.listCandidates(in: url)) ?? []) : [url]
    }
}

func format(_ value: Double?, _ spec: String = "%.1f") -> String {
    value.map { String(format: spec, $0) } ?? "-"
}

switch command {
case "check":
    let models = CoreImageRAWSource.supportedCameraModels
    let hits = models.filter { $0.uppercased().contains("7S III") || $0.uppercased().contains("7SM3") }
    print("Core Imageの対応カメラ数: \(models.count)")
    if hits.isEmpty {
        print("α7S IIIが一覧に見つかりません。名前の表記が違う可能性があるので、Sonyの機種を表示します:")
        models.filter { $0.uppercased().contains("SONY") }.forEach { print("  \($0)") }
    } else {
        hits.forEach { print("対応: \($0)") }
    }

case "info":
    let urls = expand(arguments)
    if urls.isEmpty { fail("RAWファイルが見つかりません") }
    for url in urls {
        print("■ \(url.lastPathComponent)")
        do {
            let m = try RAWMetadata.read(from: url)
            print("  カメラ: \(m.make ?? "?") \(m.model ?? "?")")
            print("  レンズ: \(m.lensModel ?? "-")")
            var shutter = "-"
            if let t = m.exposureTime {
                shutter = t < 1 ? "1/\(Int((1 / t).rounded()))" : String(format: "%.1f", t)
            }
            let iso = m.iso.map { String($0) } ?? "-"
            print("  ISO \(iso)  F\(format(m.fNumber))  \(shutter)秒  \(format(m.focalLength, "%.0f"))mm")
            print("  撮影日時: \(m.captureDate ?? "-")")
            let photo = try engine.open(url)
            let size = photo.source.nativeSize
            print("  判定: \(photo.profile.displayName)  サイズ: \(Int(size.width))×\(Int(size.height))")
            print("  撮影時WB: \(Int(photo.source.asShot.temperature))K  tint \(format(photo.source.asShot.tint))")
            let d = photo.source.detailDefaults
            print(String(format: "  デコーダ既定値: シャープネス %.2f  輝度NR %.3f  色NR %.2f", d.sharpness, d.luminanceNoiseReduction, d.colorNoiseReduction))
            if let ci = photo.source as? CoreImageRAWSource {
                let report = ci.capabilityReport.map { "\($0.0) \($0.1 ? "○" : "×")" }
                print("  デコーダ対応: " + report.joined(separator: "  "))
            }
            if let lens = photo.lensCorrection {
                let c = lens.cameraSettings
                func onOff(_ b: Bool) -> String { b ? "オート" : "切" }
                print("  レンズ補正: 補正値あり  撮影時のカメラ設定: 周辺減光 \(onOff(c.vignetting))  歪曲 \(onOff(c.distortion))  倍率色収差 \(onOff(c.chromaticAberration))")
                let corner = lens.vignettingFactor(at: 1, settings: .all)
                let scale = lens.autoScale(settings: .all, imageAspect: photo.imageAspect)
                print(String(format: "    隅の周辺減光補正 %+.2f EV  隅の歪曲 %+.2f%%  全部掛けたときの拡大 %.2f%%",
                             -log2(corner), (lens.magnification(.green, at: 1, settings: .all) - 1) * 100, (scale - 1) * 100))
            } else {
                print("  レンズ補正: 補正値なし")
            }
        } catch {
            print("  エラー: \(error)")
        }
    }

case "looks":
    for look in engine.looks.all {
        print("\(look.id)\t\(look.displayName)")
    }
    print("\n.cube ファイルは次のフォルダに置くと追加されます:\n  \(LookRegistry.userLooksDirectory.path)")

case "config":
    let path = RawgenzoPaths.configFile.path
    let exists = FileManager.default.fileExists(atPath: path)
    let e = SharedConfig.load().export
    print("設定ファイル: \(path)\(exists ? "" : " (無いので既定値)")")
    print("  保存先: \(e.directoryMode.label)" + (e.directoryMode == .sameAsRAW ? " / サブフォルダ \"\(e.subfolder)\"" : ""))
    if let f = e.fixedDirectory { print("  指定フォルダ: \(f)") }
    if let l = e.lastDirectory { print("  前回のフォルダ: \(l)") }
    print("  ファイル名: \(e.fileNameTemplate)")
    print("  形式: \(e.format)  色空間: \(e.colorSpace)  画質: \(Int(e.quality * 100))")
    print("  同名ファイル: \(e.conflictPolicy.label)")

case "name":
    guard let pattern = arguments.first else { fail("テンプレートを指定してください 例: rawdev name \"{date}_{name}\" RAWsample") }
    let t = FileNameTemplate(pattern)
    if let error = t.validate() { fail("テンプレートの誤り: \(error)") }
    let urls = expand(Array(arguments.dropFirst()))
    if urls.isEmpty {
        print("(見本) " + ((try? t.render(.sample)) ?? ""))
    }
    for (i, url) in urls.enumerated() {
        let m = (try? RAWMetadata.read(from: url)) ?? RAWMetadata()
        let name = (try? t.render(FileNameTemplate.Context(sourceURL: url, metadata: m, sequence: i + 1))) ?? "?"
        print("\(url.lastPathComponent) → \(name)")
    }

case "develop":
    var paths: [String] = []
    let shared = SharedConfig.load().export
    var outDir: URL?
    var exportFormat = shared.exportFormat
    var template = shared.template
    var sequence = 1
    var scale = 1.0
    var save = false
    var edits: [(inout DevelopSettings, Photo) -> Void] = []
    /// --crop / --aspect / --angle のどれかを指定したか(指定したときだけ枠を回転後の画像に収める)
    var cropEdited = false

    var i = 0
    func next() -> String {
        i += 1
        guard i < arguments.count else { fail("\(arguments[i - 1]) に値がありません") }
        return arguments[i]
    }
    func number() -> Double {
        let raw = next()
        guard let v = Double(raw) else { fail("数値ではありません: \(raw)") }
        return v
    }

    while i < arguments.count {
        switch arguments[i] {
        case "--out": outDir = URL(fileURLWithPath: (next() as NSString).expandingTildeInPath)
        case "--format":
            let raw = next()
            guard let f = Exporter.Format(rawValue: raw) else { fail("未知の形式: \(raw)") }
            exportFormat = f
        case "--name": template = FileNameTemplate(next())
        case "--seq-start": sequence = Int(number())
        case "--scale": scale = number()
        case "--save": save = true
        case "--exposure": let v = number(); edits.append { s, _ in s.exposure = v }
        case "--contrast": let v = number(); edits.append { s, _ in s.contrast = v }
        case "--sharpness": let v = number(); edits.append { s, _ in s.sharpness = v }
        case "--luma-nr": let v = number(); edits.append { s, _ in s.luminanceNoiseReduction = v }
        case "--color-nr": let v = number(); edits.append { s, _ in s.colorNoiseReduction = v }
        case "--saturation": let v = number(); edits.append { s, _ in s.saturation = v }
        case "--vibrance": let v = number(); edits.append { s, _ in s.vibrance = v }
        case "--hdr": let v = number(); edits.append { s, _ in s.hdr.strength = v }
        case "--highlights": let v = number(); edits.append { s, _ in s.hdr.highlights = v }
        case "--shadows": let v = number(); edits.append { s, _ in s.hdr.shadows = v }
        case "--hdr-output": edits.append { s, _ in s.hdr.extendedOutput = true }
        case "--crop":
            cropEdited = true
            let raw = next()
            let v = raw.split(separator: ",").compactMap { Double($0) }
            guard v.count == 4 else { fail("--crop は x,y,w,h の4つの数値です: \(raw)") }
            edits.append { s, _ in
                let angle = s.crop?.angle ?? 0
                s.crop = CropSettings(x: v[0], y: v[1], width: v[2], height: v[3], angle: angle)
            }
        case "--aspect":
            cropEdited = true
            let raw = next().lowercased()
            let table: [String: AspectRatio] = ["1x1": .square, "3x2": .r3x2, "4x3": .r4x3,
                                                "16x9": .r16x9, "2x3": .r2x3, "4x5": .r4x5]
            guard let a = table[raw] else { fail("未知の比率: \(raw)") }
            edits.append { s, photo in
                s.crop = .centered(aspect: a, imageAspect: photo.imageAspect, angle: s.crop?.angle ?? 0)
            }
        case "--angle":
            cropEdited = true
            let v = number()
            edits.append { s, _ in
                var c = s.crop ?? .full
                c.angle = v
                s.crop = c
            }
        case "--lens":
            let raw = next().lowercased()
            let lens: LensCorrectionSettings?
            switch raw {
            case "camera": lens = nil
            case "all": lens = .all
            case "off", "none": lens = .off
            default:
                let parts = Set(raw.split(separator: ",").map(String.init))
                guard parts.isSubset(of: ["v", "d", "ca"]), !parts.isEmpty else {
                    fail("--lens は camera / all / off / v,d,ca の組み合わせです: \(raw)")
                }
                lens = LensCorrectionSettings(vignetting: parts.contains("v"), distortion: parts.contains("d"),
                                              chromaticAberration: parts.contains("ca"))
            }
            edits.append { s, _ in s.lens = lens }
        case "--look":
            let id = next()
            guard engine.looks.look(id: id) != nil else { fail("未知のルック: \(id) (rawdev looks で確認)") }
            edits.append { s, _ in s.look = LookSelection(id: id, strength: s.look?.strength ?? 1) }
        case "--look-strength":
            let v = number()
            edits.append { s, _ in s.look?.strength = v }
        case let arg where arg.hasPrefix("--"):
            fail("未知のオプション: \(arg)")
        default:
            paths.append(arguments[i])
        }
        i += 1
    }

    let urls = expand(paths)
    if urls.isEmpty { fail("RAWファイルが見つかりません") }
    if let error = template.validate() { fail("ファイル名テンプレートの誤り: \(error)") }
    let exporter = Exporter()

    for url in urls {
        let start = Date()
        do {
            let photo = try engine.open(url)
            var settings = photo.settings
            for edit in edits { edit(&settings, photo) }
            // 傾き補正で四隅が透明にならないよう、枠を回転後の画像の内側に収める。
            // サイドカーから読んだだけの枠は書き換えない(アプリと同じく、触ったときだけ合わせる)
            if cropEdited, let crop = settings.crop, !crop.isInsideImage(imageAspect: photo.imageAspect) {
                settings.crop = crop.fitted(imageAspect: photo.imageAspect)
                if crop.width < 1 || crop.height < 1 {   // --angle だけのとき(枠が全体)は黙って収める
                    print("  \(url.lastPathComponent): 指定の枠がはみ出すので、画像に収まるよう縮めました")
                }
            }
            photo.settings = settings

            let image = try engine.pipeline.process(photo, options: RenderOptions(scale: scale))
            let format: Exporter.Format = settings.hdr.extendedOutput ? .heifHDR : exportFormat
            let dir = outDir ?? shared.directory(for: url)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let context = FileNameTemplate.Context(
                sourceURL: url, metadata: photo.metadata, sequence: sequence,
                lookName: settings.look.flatMap { engine.looks.look(id: $0.id)?.displayName },
                outputSize: image.extent.size)
            let baseName = try template.render(context)
            let out = ExportPreferences.resolve(directory: dir, baseName: baseName,
                                                fileExtension: format.fileExtension,
                                                policy: shared.conflictPolicy)
            try exporter.write(image, to: out, format: format,
                               colorSpace: shared.outputColorSpace, quality: shared.quality)
            if template.usesSequence { sequence += 1 }
            if save { try engine.save(photo) }

            let ms = Int(Date().timeIntervalSince(start) * 1000)
            print("✓ \(url.lastPathComponent) → \(out.path)  (\(Int(image.extent.width))×\(Int(image.extent.height)), \(ms)ms)")
        } catch {
            print("✗ \(url.lastPathComponent): \(error)")
        }
    }

default:
    print(usage)
    exit(1)
}
