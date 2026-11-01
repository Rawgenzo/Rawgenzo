import CoreImage
import Foundation
import OperationSurface
import RAWCore

/// 切り抜き・傾き補正の道具と、傾きの推定
extension RawgenzoTools {
    static let aspectNames = AspectRatio.allCases.map(\.rawValue)

    static func registerCrop(on surface: Surface, workspace ws: RawgenzoWorkspace) {
        let unit = JSONSchema.number(minimum: 0, maximum: 1)
        surface.register(ToolDescriptor(
            name: "set_crop", title: "切り抜き・傾き補正",
            description: "写真の切り抜き枠と傾き補正を設定してサイドカーに保存する(undo で取り消せる)。"
                + "枠の x・y・width・height は、傾き補正の後・切り抜く前の画像全体に対する比率(0〜1、左上が原点)で、4 つそろえて渡す。"
                + "get_preview に ignore_crop: true を付けた画像のピクセル座標を、その幅・高さで割った値になる。"
                + "aspect だけを渡すとその比率で中央に最大の枠、枠と aspect の両方なら枠の中心を保って比率に合わせて縮める。"
                + "angle だけを渡すと今の枠のまま傾ける。枠が傾けた画像からはみ出すときは、はみ出さない大きさに縮める(結果の notes)。"
                + "maximize: true で、今の比率のまま傾けた画像に収まる最大の大きさに広げる(アプリの「収まる最大まで広げる」と同じ。"
                + "位置はなるべく動かさない)。傾きを小さくしたとき、前に縮めた枠を戻すのに使う。angle や aspect と一緒に使える。"
                + "reset: true で切り抜きも傾きも無しに戻す。複数の写真に同じ指定を当てられる",
            input: .object([
                .init("photos", .array(of: photoID, description: "切り抜く写真の ID", minItems: 1, maxItems: 1000)),
                .init("x", unit), .init("y", unit),
                .init("width", .number(minimum: 0.05, maximum: 1)), .init("height", .number(minimum: 0.05, maximum: 1)),
                .init("angle", .number("傾き補正(度)。正 = 時計回り",
                                       minimum: CropSettings.angleRange.lowerBound, maximum: CropSettings.angleRange.upperBound)),
                .init("aspect", .string("縦横比。free(自由)・original(元の比率)・square(1:1)・r3x2・r4x3・r16x9・r2x3(縦)・r4x5(縦)",
                                        oneOf: aspectNames)),
                .init("maximize", .boolean("true で、比率を保って収まる最大の大きさに広げる(x・y・width・height と一緒には使えない)")),
                .init("reset", .boolean("true で切り抜きと傾き補正を無くす(ほかの項目と一緒には使えない)")),
            ], required: ["photos"]),
            effect: .modify)) { args, ctx in
            let rectKeys = ["x", "y", "width", "height"]
            let given = rectKeys.filter { args[$0] != nil }
            let reset = args["reset"]?.boolValue == true
            let angle = args["angle"]?.doubleValue
            let aspect = args["aspect"]?.stringValue.flatMap(AspectRatio.init(rawValue:))
            let maximize = args["maximize"]?.boolValue == true
            if reset, !given.isEmpty || angle != nil || aspect != nil || maximize {
                return .error("reset はほかの項目と一緒には使えません")
            }
            if maximize, !given.isEmpty {
                return .error("maximize は枠(x・y・width・height)と一緒には使えません(枠を指定するか、今の枠を広げるかのどちらか)")
            }
            if !given.isEmpty, given.count < 4 { return .error("x・y・width・height は 4 つそろえて渡してください") }
            if !reset, given.isEmpty, angle == nil, aspect == nil, !maximize {
                return .error("枠(x・y・width・height)・aspect・angle・maximize・reset のどれかを指定してください")
            }
            if given.count == 4, args["x"]!.doubleValue! + args["width"]!.doubleValue! > 1 + 1e-9
                || args["y"]!.doubleValue! + args["height"]!.doubleValue! > 1 + 1e-9 {
                return .error("枠が画像の外に出ています(x + width と y + height は 1 以下)")
            }
            let ids = try uniqueIDs(ws, args["photos"])

            var results: [JSONValue] = []
            for id in ids {
                let photo = try ws.photo(id)
                let before = photo.settings
                var after = before
                var notes: [String] = []
                if reset {
                    after.crop = nil
                } else {
                    let imageAspect = photo.imageAspect
                    let tilt = angle ?? before.crop?.angle ?? 0
                    var c: CropSettings
                    if given.count == 4 {
                        c = CropSettings(x: args["x"]!.doubleValue!, y: args["y"]!.doubleValue!,
                                         width: args["width"]!.doubleValue!, height: args["height"]!.doubleValue!,
                                         angle: tilt, aspect: aspect ?? .free)
                        if let a = aspect, let ratio = a.value(imageAspect: imageAspect) {
                            let shrunk = c.shrunk(toAspect: ratio, imageAspect: imageAspect)
                            if differs(shrunk, c) { notes.append("枠の中心を保って \(a.label) に合わせて縮めた") }
                            c = shrunk
                        }
                    } else if let a = aspect {
                        c = .centered(aspect: a, imageAspect: imageAspect, angle: tilt)
                    } else {
                        c = before.crop ?? .full
                        c.angle = tilt
                    }
                    let requested = c
                    c = c.clamped()
                    if !c.isInsideImage(imageAspect: imageAspect) { c = c.fitted(imageAspect: imageAspect) }
                    // 等しいかではなく差の大きさで比べる。y 0.19・高さ 0.81 のように下端がちょうど 1 の枠は、
                    // clamped の 1 - 0.81 = 0.18999999999999995 で値がわずかに変わり、縮めていないのに注記が付いた(試験)
                    if maximize {
                        // アプリの「収まる最大まで広げる」と同じ計算。傾きを小さくしても枠は自動では広がらないので、
                        // AI が +2.5° → +2.05° と戻したとき、縮んだ枠のまま残った(2026-10-20 の試験。AI はアプリのボタンを案内した)
                        let widened = c.maximized(imageAspect: imageAspect)
                        if differs(widened, c) { notes.append("収まる最大の大きさにした") }
                        c = widened
                    } else if differs(c, requested) {
                        notes.append("枠が傾けた画像からはみ出すので、はみ出さない大きさに縮めた")
                    }
                    after.crop = c == .full ? nil : c
                }
                if after != before { try commit(ws, ctx, photo, from: before, to: after) }
                var row: [String: JSONValue] = ["photo": .string(id), "crop": ["from": cropJSON(before.crop), "to": cropJSON(after.crop)]]
                let size = photo.source.nativeSize
                let c = after.crop ?? .full
                row["cropped_size"] = [.number((Double(size.width) * c.width).rounded()),
                                       .number((Double(size.height) * c.height).rounded())]
                if after == before { notes.append("変更なし") }
                if !notes.isEmpty { row["notes"] = .array(notes.map { .string($0) }) }
                results.append(.object(row))
            }
            return warned(.json(["results": .array(results)]), ws, try ids.map { try ws.url(for: $0) })
        }
    }

    /// 枠が目に見えて違うか(小数の誤差は同じとみなす)
    static func differs(_ a: CropSettings, _ b: CropSettings) -> Bool {
        [a.x - b.x, a.y - b.y, a.width - b.width, a.height - b.height, a.angle - b.angle].contains { abs($0) > 1e-6 }
    }

    static func registerTilt(on surface: Surface, workspace ws: RawgenzoWorkspace) {
        surface.register(ToolDescriptor(
            name: "estimate_tilt", title: "傾きの手がかり",
            description: "写真の傾きを直すための手がかりを返す。長い直線(水平・垂直から 10° 以内)に番号を付けた画像と、"
                + "各線の角度、人物の目(E1…)・肩(S1…)を結ぶ線と、首と腰を結ぶ体の軸(T1…。垂直の手がかり)の角度。"
                + "角度はどれも set_crop の angle に入れるとその線が水平(垂直)になる値で、傾き補正の前からの値(今の angle に足すのではない)。"
                + "画像を見て、本当に水平・垂直なもの(建物や家具の縁・柱・水平線)の番号を segments に渡すと、長さで重みを付けた角度を返す。"
                + "奥へ伸びる線(遠近で斜めに見える)・ブラインドや斜めに置かれた物は使わない。"
                + "縦の線が左右で開いているとき(カメラを上下に向けて撮った)は vertical_fan の angle_at_center を使うか、中央に近い縦の線を選ぶ。"
                + "人物写真では人物の線(subjects)も手がかりになる。目・肩は首をかしげたり肩を傾けたりすると大きく出るので、"
                + "「身体の傾き」には体の軸(T)を使い、1 本では決めない。体の軸はその人の姿勢(寄りかかる・前かがみ)も含む。"
                + "confidence が 0.3 未満の線(座っていて腰が隠れているときの体の軸など)は当てにしない。"
                + "線と人物で食い違うとき、どれを基準にするか決められないときは人に聞く。"
                + "そのとき、両方の値だけでなく間の角度(人物を立てつつ背景の傾きを抑える)も選択肢に入れる。2 秒ほどかかる",
            input: .object([
                .init("photo", photoID),
                .init("segments", .array(of: .integer(minimum: 1), description: "水平・垂直の基準にする直線の番号(前の結果の画像の番号)")),
                .init("subjects", .array(of: .string(), description: "基準にする人物の線(E1・S2・T1 など)")),
                .init("image", .boolean("番号を描いた画像を返すか(既定 true。番号が分かっていて角度だけ欲しいときは false)")),
                .init("long_edge", .integer("画像の長辺(既定 768)", minimum: 384, maximum: 1600)),
            ], required: ["photo"]),
            effect: .read)) { args, _ in
            let photo = try ws.photo(args["photo"]!.stringValue!)
            let report = try TiltEstimator.estimate(photo, settings: photo.settings, pipeline: ws.engine.pipeline)
            let subjects = TiltEstimator.subjectIDs(report.subjects)
            func point(_ p: CGPoint) -> JSONValue { [.number(Double(p.x).rounded(toPlaces: 4)), .number(Double(p.y).rounded(toPlaces: 4))] }
            func deg(_ v: Double) -> JSONValue { .number(v.rounded(toPlaces: 2)) }
            var o: [String: JSONValue] = [
                "photo": .string(ws.id(for: photo.url)),
                "current_angle": deg(photo.settings.crop?.angle ?? 0),
                "segments": .array(report.segments.map {
                    ["id": .number(Double($0.id)), "axis": .string($0.axis.rawValue), "angle": deg($0.angle),
                     "length": .number($0.length.rounded(toPlaces: 4)), "from": point($0.from), "to": point($0.to)]
                }),
                "subjects": .array(subjects.map { id, m in
                    ["id": .string(id), "kind": .string(m.kind.rawValue), "angle": deg(m.angle), "center": point(m.center),
                     "confidence": .number(m.confidence.rounded(toPlaces: 2))]
                }),
            ]
            var notes: [String] = []
            var chosen: [String: JSONValue] = [:]
            if let ids = args["segments"]?.arrayValue?.compactMap(\.intValue), !ids.isEmpty {
                let picked = report.segments.filter { ids.contains($0.id) }
                let missing = ids.filter { id in !picked.contains { $0.id == id } }
                if !missing.isEmpty { notes.append("見つからない番号: \(missing.map(String.init).joined(separator: ", "))(番号は呼ぶたびに同じ。前の結果の番号を使う)") }
                if let c = TiltEstimator.combinedAngle(picked) {
                    chosen["segments"] = ["angle": deg(c.angle), "spread": deg(c.spread), "count": .number(Double(picked.count))]
                    if c.spread > 0.7 { notes.append("選んだ線の角度が ±\(String(format: "%.1f", c.spread))° ばらついている。遠近で斜めに見える線が混ざっていないか確かめる") }
                }
            }
            if let ids = args["subjects"]?.arrayValue?.compactMap(\.stringValue), !ids.isEmpty {
                let picked = subjects.filter { ids.contains($0.0) }.map(\.1)
                if picked.count < ids.count { notes.append("見つからない人物の線がある") }
                if !picked.isEmpty {
                    let mean = picked.map(\.angle).reduce(0, +) / Double(picked.count)
                    let spread = (picked.map { ($0.angle - mean) * ($0.angle - mean) }.reduce(0, +) / Double(picked.count)).squareRoot()
                    chosen["subjects"] = ["angle": deg(mean), "spread": deg(spread), "count": .number(Double(picked.count))]
                }
            }
            if !chosen.isEmpty { o["chosen"] = .object(chosen) }
            if report.segments.isEmpty { notes.append("長い直線が見つからない(自然の風景など)。人物の線か、目で見て決める") }
            if let fan = TiltEstimator.verticalFan(report.segments) {
                o["vertical_fan"] = ["angle_at_center": deg(fan.angleAtCenter), "angle_at_left": deg(fan.angleAtLeft),
                                     "angle_at_right": deg(fan.angleAtRight), "count": .number(Double(fan.count))]
                notes.append(String(format: "縦の線が左右で開いている(左端 %+.1f°、右端 %+.1f°)。カメラを上か下に向けて撮っている。"
                    + "傾きは画像の中央での値 %+.1f°(端の縦の線を選ぶとずれる)", fan.angleAtLeft, fan.angleAtRight, fan.angleAtCenter))
            }
            if photo.lensCorrection != nil, photo.effectiveLensSettings(photo.settings)?.distortion == false {
                notes.append("歪曲補正が切れているので、画面の端の直線は曲がって測りにくい(set_lens_correction で distortion をオンにすると正確になる)")
            }
            if !notes.isEmpty { o["notes"] = .array(notes.map { .string($0) }) }

            var content: [ToolContent] = [.json(.object(o))]
            if args["image"]?.boolValue ?? true {
                let image = try ws.engine.pipeline.processFitting(photo, settings: TiltEstimator.measuringSettings(photo.settings),
                                                                  longEdge: args["long_edge"]?.intValue ?? 768)
                let marked = try PreviewOverlay.draw(on: image, frame: nil, marks: TiltEstimator.marks(report))
                content.append(.image(data: try PreviewEncoder.jpeg(marked, quality: 0.75), mimeType: "image/jpeg"))
            }
            return warned(ToolResult(content), ws, [photo.url])
        }
    }

    static func cropJSON(_ crop: CropSettings?) -> JSONValue {
        guard let c = crop else { return .null }
        return ["x": .number(c.x.rounded(toPlaces: 4)), "y": .number(c.y.rounded(toPlaces: 4)),
                "width": .number(c.width.rounded(toPlaces: 4)), "height": .number(c.height.rounded(toPlaces: 4)),
                "angle": .number(c.angle.rounded(toPlaces: 4)), "aspect": .string(c.aspect.rawValue)]
    }
}
