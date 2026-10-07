import Foundation

/// 書き出しファイル名のテンプレート。
///
///   "{date}_{name}"             → 20260914_DSC01234
///   "{date:yyyy-MM-dd}_{seq:3}" → 2026-09-14_007
///   "{model}_ISO{iso}_{name}"   → ILCE-7SM3_ISO12800_DSC01234
///
/// `{変数}` または `{変数:書式}` を値に置き換える。`{{` と `}}` で波括弧そのものを書ける。
/// 拡張子は付けない(書き出し形式から自動で付く)。
public struct FileNameTemplate: Equatable, Sendable {
    public var pattern: String

    public init(_ pattern: String) { self.pattern = pattern }

    public static let `default` = FileNameTemplate("{name}")

    // MARK: - 変数の一覧(UIのヘルプ・挿入ボタン用)

    public struct Variable: Sendable {
        public let token: String
        public let summary: String
        /// 書式の指定例(省略可)
        public let formatHint: String?
    }

    public static let variables: [Variable] = [
        Variable(token: "name", summary: "元のファイル名(拡張子なし)", formatHint: nil),
        Variable(token: "folder", summary: "元のフォルダ名", formatHint: nil),
        Variable(token: "date", summary: "撮影日 (既定 yyyyMMdd)", formatHint: "date:yyyy-MM-dd"),
        Variable(token: "time", summary: "撮影時刻 (既定 HHmmss)", formatHint: "time:HH.mm"),
        Variable(token: "now", summary: "書き出した日時 (既定 yyyyMMdd-HHmmss)", formatHint: "now:yyyyMMdd"),
        Variable(token: "seq", summary: "連番 (既定 4桁)", formatHint: "seq:3"),
        Variable(token: "make", summary: "メーカー (SONY)", formatHint: nil),
        Variable(token: "model", summary: "機種名 (ILCE-7SM3)", formatHint: nil),
        Variable(token: "lens", summary: "レンズ名", formatHint: nil),
        Variable(token: "iso", summary: "ISO感度", formatHint: nil),
        Variable(token: "f", summary: "F値 (2.8)", formatHint: nil),
        Variable(token: "shutter", summary: "シャッター速度 (1-250 / 2.5s)", formatHint: nil),
        Variable(token: "focal", summary: "焦点距離 mm (35)", formatHint: nil),
        Variable(token: "look", summary: "ルック名(なしなら空)", formatHint: nil),
        Variable(token: "width", summary: "書き出し画像の幅 px", formatHint: nil),
        Variable(token: "height", summary: "書き出し画像の高さ px", formatHint: nil),
    ]

    // MARK: - 値の材料

    public struct Context: Sendable {
        public var sourceURL: URL
        public var metadata: RAWMetadata
        public var exportDate: Date
        public var sequence: Int
        public var lookName: String?
        public var outputSize: CGSize?

        public init(sourceURL: URL, metadata: RAWMetadata, exportDate: Date = Date(),
                    sequence: Int = 1, lookName: String? = nil, outputSize: CGSize? = nil) {
            self.sourceURL = sourceURL
            self.metadata = metadata
            self.exportDate = exportDate
            self.sequence = sequence
            self.lookName = lookName
            self.outputSize = outputSize
        }

        /// 設定画面のプレビュー用の見本
        public static let sample = Context(
            sourceURL: URL(fileURLWithPath: "/Photos/2026-09 Kanazawa/DSC01234.ARW"),
            metadata: RAWMetadata(make: "SONY", model: "ILCE-7SM3", iso: 12800, exposureTime: 1.0 / 250,
                                  fNumber: 2.8, focalLength: 35, lensModel: "FE 35mm F1.4 GM",
                                  pixelWidth: 4240, pixelHeight: 2832, captureDate: "2026:09:14 18:42:07"),
            exportDate: Date(), sequence: 7, lookName: "フィルム風",
            outputSize: CGSize(width: 4240, height: 2832))
    }

    public enum TemplateError: Error, Equatable, CustomStringConvertible {
        case unknownVariable(String)
        case unclosedBrace
        case badSequenceDigits(String)
        public var description: String {
            switch self {
            case .unknownVariable(let v): return "未知の変数です: {\(v)}"
            case .unclosedBrace: return "「{」が閉じられていません"
            case .badSequenceDigits(let s): return "連番の桁数は1〜9の数字で指定してください: \(s)"
            }
        }
    }

    // MARK: - 解析

    private enum Piece: Equatable {
        case text(String)
        case variable(name: String, format: String?)
    }

    private func parse() throws -> [Piece] {
        var pieces: [Piece] = []
        var text = ""
        var i = pattern.startIndex
        while i < pattern.endIndex {
            let c = pattern[i]
            let next = pattern.index(after: i)
            if c == "{" {
                if next < pattern.endIndex, pattern[next] == "{" {      // {{ → {
                    text.append("{"); i = pattern.index(after: next); continue
                }
                guard let close = pattern[next...].firstIndex(of: "}") else { throw TemplateError.unclosedBrace }
                if !text.isEmpty { pieces.append(.text(text)); text = "" }
                let body = String(pattern[next..<close])
                if let colon = body.firstIndex(of: ":") {
                    pieces.append(.variable(name: String(body[..<colon]).trimmingCharacters(in: .whitespaces),
                                            format: String(body[body.index(after: colon)...])))
                } else {
                    pieces.append(.variable(name: body.trimmingCharacters(in: .whitespaces), format: nil))
                }
                i = pattern.index(after: close)
            } else if c == "}", next < pattern.endIndex, pattern[next] == "}" {  // }} → }
                text.append("}"); i = pattern.index(after: next)
            } else {
                text.append(c); i = next
            }
        }
        if !text.isEmpty { pieces.append(.text(text)) }
        return pieces
    }

    /// 書式の誤りを調べる(UIで入力中に表示する用)
    public func validate() -> TemplateError? {
        do {
            for case let .variable(name, format) in try parse() {
                guard Self.variables.contains(where: { $0.token == name }) else {
                    return .unknownVariable(name)
                }
                if name == "seq", let f = format, Int(f).map({ !(1...9).contains($0) }) ?? true {
                    return .badSequenceDigits(f)
                }
            }
            return nil
        } catch let e as TemplateError {
            return e
        } catch {
            return .unclosedBrace
        }
    }

    /// 連番を使うテンプレートか(使うときだけ書き出し後に番号を進める)
    public var usesSequence: Bool {
        ((try? parse()) ?? []).contains { if case .variable("seq", _) = $0 { return true }; return false }
    }

    // MARK: - 生成

    /// ファイル名(拡張子なし)を作る。ファイル名に使えない文字は置き換える。
    public func render(_ ctx: Context) throws -> String {
        if let error = validate() { throw error }
        var out = ""
        for piece in try parse() {
            switch piece {
            case .text(let t): out += t
            case .variable(let name, let format): out += Self.sanitize(value(name, format, ctx))
            }
        }
        // 空の変数で前後に残った区切り文字を落とす
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: " _-.").union(.whitespaces))
        let result = Self.sanitize(trimmed)
        return result.isEmpty ? ctx.sourceURL.deletingPathExtension().lastPathComponent : result
    }

    private func value(_ name: String, _ format: String?, _ ctx: Context) -> String {
        let m = ctx.metadata
        switch name {
        case "name": return ctx.sourceURL.deletingPathExtension().lastPathComponent
        case "folder": return ctx.sourceURL.deletingLastPathComponent().lastPathComponent
        case "date": return Self.format(captureDate(ctx), format ?? "yyyyMMdd")
        case "time": return Self.format(captureDate(ctx), format ?? "HHmmss")
        case "now": return Self.format(ctx.exportDate, format ?? "yyyyMMdd-HHmmss")
        case "seq":
            let digits = format.flatMap(Int.init) ?? 4
            return String(format: "%0\(digits)ld", ctx.sequence)
        case "make": return m.make ?? ""
        case "model": return m.model ?? ""
        case "lens": return m.lensModel ?? ""
        case "iso": return m.iso.map(String.init) ?? ""
        case "f":
            guard let f = m.fNumber else { return "" }
            return f.rounded() == f ? String(Int(f)) : String(format: "%.1f", f)
        case "shutter":
            guard let t = m.exposureTime, t > 0 else { return "" }
            if t < 1 { return "1-\(Int((1 / t).rounded()))" }
            return t.rounded() == t ? "\(Int(t))s" : String(format: "%.1fs", t)
        case "focal": return m.focalLength.map { String(Int($0.rounded())) } ?? ""
        case "look": return ctx.lookName ?? ""
        case "width": return ctx.outputSize.map { String(Int($0.width)) } ?? ""
        case "height": return ctx.outputSize.map { String(Int($0.height)) } ?? ""
        default: return ""
        }
    }

    /// EXIFの撮影日時。無ければファイルの更新日時
    private func captureDate(_ ctx: Context) -> Date {
        if let s = ctx.metadata.captureDate, let d = Self.exifFormatter.date(from: s) { return d }
        let attrs = try? FileManager.default.attributesOfItem(atPath: ctx.sourceURL.path)
        return attrs?[.modificationDate] as? Date ?? ctx.exportDate
    }

    private static let exifFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f
    }()

    private static func format(_ date: Date, _ pattern: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = pattern
        return f.string(from: date)
    }

    /// macOSのファイル名に使えない・紛らわしい文字を置き換える
    static func sanitize(_ s: String) -> String {
        var out = ""
        for ch in s {
            switch ch {
            case "/", ":", "\\": out.append("-")
            case "\n", "\r", "\t": out.append(" ")
            default:
                if ch.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) { out.append(ch) }
            }
        }
        // 先頭の "." は隠しファイルになるので落とす
        while out.hasPrefix(".") { out.removeFirst() }
        return out
    }
}
