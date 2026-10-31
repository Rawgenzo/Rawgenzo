import Foundation
import RAWCore
import OperationSurface
import RawgenzoSurface

// rawdev: サンプルRAWで現像エンジンを確かめるためのコマンドラインツール

let usage = """
使い方:
  rawdev check                     このMacのCore Imageがα7S IIIに対応しているか確認
  rawdev info <ファイル|フォルダ>...   メタデータとカメラ判定結果を表示
  rawdev looks                     使えるルック(〜風フィルター)の一覧
  rawdev params                    数値で調整するパラメータの一覧(範囲・基準値・説明)
  rawdev mcp [<フォルダ>] [--log <ファイル>]
                                   MCP サーバー(stdio)。MCP クライアント(Claude Code など)から起動して、
                                   フォルダの写真の現像設定を AI に操作させる。フォルダを省くとアプリが最後に開いたフォルダ。
                                   --log は呼び出しごとの記録(JSON Lines)
  rawdev tilt <ファイル|フォルダ>...       傾きの推定(線と人物を基準に、直す角度)
  rawdev stats <ファイル|フォルダ>... [--json] [--long-edge <px>] [--preview <フォルダ>]
                                   今の設定(サイドカー)で現像した結果の明るさ・白飛び・色の統計
                                   (--preview は AI に見せるのと同じ縮小 JPEG を書き出す)
  rawdev config                    設定ファイル (~/.Rawgenzo/config.json) の書き出し設定を表示
  rawdev name <テンプレート> <ファイル>...  ファイル名テンプレートの結果を表示(書き出さない)
  rawdev develop <ファイル|フォルダ>... [オプション]

develop のオプション:
  --out <フォルダ>         出力先 (既定: 設定の保存先。未設定ならRAWと同じフォルダの developed/)
  --name <テンプレート>    出力ファイル名 例: "{date}_{name}" (既定: 設定のテンプレート)
  --seq-start <番号>       {seq} の開始番号 (既定: 1。CLIは設定の連番を進めない)
  --format <形式>          jpeg | heif | tiff16 | heif-hdr (既定: 設定の形式)
  --exposure <EV>          露出補正 -3...3 例: 0.7
  --contrast <値>          コントラスト -1.2...1.2 (0 = そのまま。アプリの -120...+120 に当たる)
  --sharpness <値>         シャープネス 0...6 (既定 1。等倍で描くときだけ効く)
  --luma-nr <値>           輝度ノイズ除去 0...1 (既定は ISO に応じてデコーダが決める)
  --color-nr <値>          色ノイズ除去 0...2 (既定 0.5)
  --saturation <倍率>      彩度 0...2 例: 1.2 (1 = そのまま)
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
  (数値の調整は範囲外を端に丸める。範囲はアプリのスライダーと同じ)
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

/// 数値の調整オプション → ParameterCatalog の id
let parameterOptions: [String: String] = [
    "--exposure": "exposure", "--contrast": "contrast",
    "--sharpness": "sharpness", "--luma-nr": "luminanceNoiseReduction", "--color-nr": "colorNoiseReduction",
    "--saturation": "saturation", "--vibrance": "vibrance",
    "--hdr": "hdr.strength", "--highlights": "hdr.highlights", "--shadows": "hdr.shadows",
]

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
            let modes = [ExifLabels.exposureProgram(m.exposureProgram).map { "露出 \($0)" },
                         m.exposureBias.map { String(format: "補正 %+.1fEV", $0) },
                         ExifLabels.meteringMode(m.meteringMode).map { "測光 \($0)" },
                         ExifLabels.whiteBalance(m.whiteBalance).map { "WB \($0)" },
                         ExifLabels.flash(m.flash).map { "フラッシュ \($0)" }].compactMap { $0 }
            if !modes.isEmpty { print("  " + modes.joined(separator: "  ")) }
            if let f = m.focusPoint {
                let u = FocusPointMapping.upright(f, orientation: m.orientation)
                print(String(format: "  フォーカス位置: (%.3f, %.3f)(写真の向きで。左上が原点)", u.x, u.y))
            }
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
        print("\(look.id)\t\(look.displayName)" + (look.summary.map { "\t\($0)" } ?? ""))
    }
    print("\n.cube ファイルは次のフォルダに置くと追加されます:\n  \(LookRegistry.userLooksDirectory.path)")

case "params":
    for group in ParameterGroup.allCases {
        print("■ \(group.label)")
        for p in ParameterCatalog.parameters(in: group) {
            let baseline: String
            switch p.baseline {
            case .fixed(let v): baseline = p.formatted(v)
            case .asShotTemperature, .asShotTint: baseline = "撮影時の値"
            default: baseline = "デコーダの既定値"
            }
            let unit = p.unit.map { " \($0)" } ?? ""
            print("  \(p.id)  \(p.label)  \(p.range.lowerBound)...\(p.range.upperBound)\(unit)  基準: \(baseline)")
            print("    \(p.summary)")
        }
    }

case "tilt":
    // --preview <フォルダ>: 候補の線に番号を描いた JPEG を書き出す(AI に見せる画像と同じもの)
    var tiltPreview: URL?
    var tiltPaths: [String] = []
    var ti = 0
    while ti < arguments.count {
        if arguments[ti] == "--preview", ti + 1 < arguments.count {
            tiltPreview = URL(fileURLWithPath: (arguments[ti + 1] as NSString).expandingTildeInPath); ti += 2; continue
        }
        tiltPaths.append(arguments[ti]); ti += 1
    }
    let urls = expand(tiltPaths)
    if urls.isEmpty { fail("RAWファイルが見つかりません") }
    for url in urls {
        do {
            let start = Date()
            let photo = try engine.open(url)
            let r = try TiltEstimator.estimate(photo, settings: photo.settings, pipeline: engine.pipeline)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            print("■ \(url.lastPathComponent)  (\(ms)ms。角度は set_crop の angle に入れると、その線が水平・垂直になる値)")
            if r.segments.isEmpty { print("  直線: 見つからない") }
            for g in r.segments {
                print(String(format: "  %2d %@ %+.2f°  長さ %.2f  (%.2f, %.2f)→(%.2f, %.2f)", g.id, g.axis == .horizontal ? "水平" : "垂直",
                             g.angle, g.length, g.from.x, g.from.y, g.to.x, g.to.y))
            }
            if let dir = tiltPreview {
                let image = try engine.pipeline.processFitting(photo, settings: TiltEstimator.measuringSettings(photo.settings), longEdge: 1024)
                let out = try PreviewOverlay.draw(on: image, frame: nil, marks: TiltEstimator.marks(r))
                let file = dir.appendingPathComponent(url.deletingPathExtension().lastPathComponent + "_tilt.jpg")
                try PreviewEncoder.jpeg(out).write(to: file)
            }
            if let fan = TiltEstimator.verticalFan(r.segments) {
                print(String(format: "  縦の線が開いている: 左端 %+.2f°  中央 %+.2f°  右端 %+.2f°(%d 本)",
                             fan.angleAtLeft, fan.angleAtCenter, fan.angleAtRight, fan.count))
            }
            if r.subjects.isEmpty { print("  人物: 見つからない") }
            for m in r.subjects {
                print(String(format: "  人物(%@): %+.2f°  位置 (%.2f, %.2f)  確からしさ %.2f", ["eyes": "目", "shoulders": "肩", "torso": "体の軸"][m.kind.rawValue]!, m.angle, m.center.x, m.center.y, m.confidence))
            }
        } catch {
            FileHandle.standardError.write("\(url.lastPathComponent): \(error)\n".data(using: .utf8)!)
        }
    }

case "stats":
    var paths: [String] = []
    var asJSON = false
    var longEdge = ImageStats.defaultLongEdge
    var previewDir: URL?
    var k = 0
    while k < arguments.count {
        let arg = arguments[k]
        func value() -> String {
            k += 1
            guard k < arguments.count else { fail("\(arg) に値がありません") }
            return arguments[k]
        }
        switch arg {
        case "--json": asJSON = true
        case "--long-edge":
            let raw = value()
            guard let v = Int(raw), v >= 16 else { fail("--long-edge は 16 以上の整数です: \(raw)") }
            longEdge = v
        case "--preview": previewDir = URL(fileURLWithPath: (value() as NSString).expandingTildeInPath)
        case let a where a.hasPrefix("--"): fail("未知のオプション: \(a)")
        default: paths.append(arg)
        }
        k += 1
    }
    let urls = expand(paths)
    if urls.isEmpty { fail("RAWファイルが見つかりません") }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    for url in urls {
        do {
            let start = Date()
            let photo = try engine.open(url)
            let image = try engine.pipeline.processFitting(photo, settings: photo.settings, longEdge: longEdge)
            let stats = try ImageStats.compute(image, maxLongEdge: longEdge)
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            if asJSON {
                print(String(decoding: try encoder.encode(stats), as: UTF8.self))
            } else {
                print("■ \(url.lastPathComponent)  (\(stats.width)×\(stats.height) で計算、\(ms)ms)")
                print(String(format: "  輝度: 平均 %.3f  中央 %.3f  1%%点 %.3f  99%%点 %.3f",
                             stats.meanLuminance, stats.medianLuminance, stats.p01Luminance, stats.p99Luminance))
                print(String(format: "  白飛び %.2f%%  黒つぶれ %.2f%%  平均RGB %.3f / %.3f / %.3f",
                             stats.highlightClipping * 100, stats.shadowClipping * 100,
                             stats.meanRGB[0], stats.meanRGB[1], stats.meanRGB[2]))
                let bars = " ▁▂▃▄▅▆▇█"
                let peak = stats.histogram.max() ?? 1
                let hist = stats.histogram.map { v -> Character in
                    let i = peak > 0 ? Int((v / peak * 8).rounded()) : 0
                    return bars[bars.index(bars.startIndex, offsetBy: i)]
                }
                print("  ヒストグラム 暗[\(String(hist))]明")
                print("  区画ごとの明るさ(上から):")
                for row in stats.grid {
                    let cells = row.map { String(format: "%.2f", 0.2126 * $0[0] + 0.7152 * $0[1] + 0.0722 * $0[2]) }
                    print("    " + cells.joined(separator: " "))
                }
                let json = try encoder.encode(stats)
                print("  JSON にすると \(json.count) バイト")
            }
            if let dir = previewDir {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let out = dir.appendingPathComponent(url.deletingPathExtension().lastPathComponent + "_preview.jpg")
                let data = try PreviewEncoder.jpeg(image)
                try data.write(to: out)
                if !asJSON {
                    print("  縮小画像: \(out.path)  (\(Int(image.extent.width))×\(Int(image.extent.height))、\(data.count / 1024) KB)")
                }
            }
        } catch {
            FileHandle.standardError.write("✗ \(url.lastPathComponent): \(error)\n".data(using: .utf8)!)
        }
    }

case "mcp":
    // 標準出力は MCP のメッセージ専用。ここでは print を使わない(説明・エラーは標準エラーへ)
    func logError(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
    var folderPath: String?
    var logURL: URL?
    var k = 0
    while k < arguments.count {
        switch arguments[k] {
        case "--log":
            k += 1
            guard k < arguments.count else { fail("--log に値がありません") }
            logURL = URL(fileURLWithPath: (arguments[k] as NSString).expandingTildeInPath)
        case let a where a.hasPrefix("--"): fail("未知のオプション: \(a)")
        default: folderPath = arguments[k]
        }
        k += 1
    }
    func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
    let folder: URL
    if let folderPath {
        folder = URL(fileURLWithPath: (folderPath as NSString).expandingTildeInPath, isDirectory: true)
        guard isDirectory(folder) else { fail("フォルダが見つかりません: \(folder.path)") }
    } else {
        // 省いたときは、アプリが最後に開いたフォルダ(無ければピクチャ、それも無ければホーム)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [SharedConfig.load().lastFolder.map { URL(fileURLWithPath: $0, isDirectory: true) },
                          home.appendingPathComponent("Pictures", isDirectory: true)].compactMap { $0 }
        folder = candidates.first(where: isDirectory) ?? home
        logError("作業フォルダ: \(folder.path)")
    }
    var logHandle: FileHandle?
    if let logURL {
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        logHandle = try? FileHandle(forWritingTo: logURL)
        _ = try? logHandle?.seekToEnd()
    }
    let iso = ISO8601DateFormatter()
    let logLock = NSLock()
    func logCall(_ r: MCPServer.CallRecord, via: String) {
        // 画像のトークン数は「幅×高さ÷750」の目安(実際の値はモデルによって違う)
        let imageTokens = r.images.reduce(0) { $0 + $1.width * $1.height / 750 }
        let entry: JSONValue = [
            "date": .string(iso.string(from: Date())), "tool": .string(r.tool), "is_error": .bool(r.isError),
            "duration_ms": .number(Double(r.durationMs)), "text_bytes": .number(Double(r.textBytes)),
            "images": .array(r.images.map { [.number(Double($0.width)), .number(Double($0.height)), .number(Double($0.bytes))] }),
            "image_tokens_estimate": .number(Double(imageTokens)),
            "arguments": r.arguments, "summary": .string(r.summary), "via": .string(via),
        ]
        logLock.lock(); defer { logLock.unlock() }
        logHandle?.write(Data((entry.jsonString() + "\n").utf8))
        logError("[rawgenzo] \(r.tool) \(r.isError ? "失敗" : "成功") \(r.durationMs)ms 文字 \(r.textBytes)B 画像 \(r.images.count) 枚(\(via))")
    }

    // 道具を呼ぶたびに、Rawgenzo アプリが AI からの操作を受け付けているかを確かめ、受け付けていればアプリに中継する
    // (AI の変更がアプリの画面にその場で出て、アプリの自動保存が上書きしない)。受け付けていなければ自分で処理する。
    // 会話の途中でアプリを起動・終了しても切り替わる
    let surface = RawgenzoTools.makeSurface(workspace: RawgenzoWorkspace(folder: folder, engine: engine))
    let server = MCPServer(surface: surface)
    server.onToolCall = { logCall($0, via: "rawdev") }
    let router = MCPRouter(local: server, preamble: [RawgenzoBridge.handshake(folder: folder)]) {
        UnixSocketBridge.connect(path: RawgenzoBridge.socketPath)
    }
    router.onRemoteToolCall = { logCall($0, via: "app") }
    router.onSwitch = { logError("[rawgenzo] \($0)") }
    logError("[rawgenzo] MCP サーバーを開始: \(folder.path)(\((try? engine.listCandidates(in: folder).count) ?? 0) 枚)")
    router.run()

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
        case let flag where parameterOptions[flag] != nil:
            // 範囲は ParameterCatalog(アプリのスライダーと同じ)。範囲外は端に丸めて知らせる
            let p = ParameterCatalog[parameterOptions[flag]!]
            let v = number()
            let clamped = p.clamp(v)
            if clamped != v {
                print("\(flag) \(v) は範囲 \(p.range.lowerBound)...\(p.range.upperBound) の外なので \(clamped) にします")
            }
            edits.append { s, _ in p.set(clamped, in: &s) }
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
