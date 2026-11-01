import Foundation
import RAWCore

/// 現像設定を「項目」単位で比べ・写す。取り消しで、その取引が変えた項目だけを戻し、
/// 後から別の操作が同じ項目を変えていたら断るために使う(履歴ではなく今の状態で確かめる)
enum SettingsFields {
    /// 数値パラメータ(ParameterCatalog の id)以外の項目。項目を足すときはここに 1 行足す
    struct Field {
        let id: String
        let label: String
        let same: (DevelopSettings, DevelopSettings) -> Bool
        let copy: (DevelopSettings, inout DevelopSettings) -> Void
        let describe: (DevelopSettings) -> String

        init<V: Equatable>(_ id: String, _ label: String, _ path: WritableKeyPath<DevelopSettings, V>,
                           describe: @escaping (V) -> String) {
            self.id = id
            self.label = label
            same = { $0[keyPath: path] == $1[keyPath: path] }
            copy = { $1[keyPath: path] = $0[keyPath: path] }
            self.describe = { describe($0[keyPath: path]) }
        }
    }

    static let others: [Field] = [
        Field("crop", "クロップ", \.crop) { $0 == nil ? "なし" : "あり" },
        Field("look", "ルック", \.look) { $0.map { "\($0.id) \(Int($0.strength * 100))%" } ?? "なし" },
        Field("lens", "レンズ補正", \.lens) { $0 == nil ? "カメラ設定に従う" : "指定あり" },
        Field("hdr.extendedOutput", "HDR 出力", \.hdr.extendedOutput) { $0 ? "オン" : "オフ" },
        Field("colorAdjust", "色別補正", \.colorAdjust) { $0.map { $0.isNeutral ? "なし" : "あり" } ?? "なし" },
        Field("toneCurve", "トーンカーブ", \.toneCurve) { $0.map { $0.isNeutral ? "なし" : "あり" } ?? "なし" },
    ]

    static func other(_ id: String) -> Field? { others.first { $0.id == id } }

    static func label(_ id: String) -> String {
        ParameterCatalog.descriptor(id)?.label ?? other(id)?.label ?? id
    }

    /// 2 つの設定で値が違う項目(保存されている値で比べる。未指定と、基準値と同じ値の指定は別のものとして扱う)
    static func changed(_ a: DevelopSettings, _ b: DevelopSettings) -> [String] {
        (ParameterCatalog.all.map(\.id) + others.map(\.id)).filter { !same($0, a, b) }
    }

    static func same(_ id: String, _ a: DevelopSettings, _ b: DevelopSettings) -> Bool {
        if let p = ParameterCatalog.descriptor(id) { return p.storedValue(a) == p.storedValue(b) }
        return other(id)?.same(a, b) ?? true
    }

    /// source の項目の値を dest に写す
    static func copy(_ id: String, from source: DevelopSettings, to dest: inout DevelopSettings) {
        if let p = ParameterCatalog.descriptor(id) {
            if let v = p.storedValue(source) { p.set(v, in: &dest) } else { p.reset(&dest) }
            return
        }
        other(id)?.copy(source, &dest)
    }

    /// 説明用の値(エラーの文で AI に見せる)
    static func describe(_ id: String, _ s: DevelopSettings) -> String {
        if let p = ParameterCatalog.descriptor(id) {
            return p.storedValue(s).map { p.formatted($0) } ?? "未指定(基準値)"
        }
        return other(id)?.describe(s) ?? "?"
    }
}

/// 取り消すと、後から別の操作で変えられた値を消してしまう
struct UndoWouldDiscardChanges: Error, CustomStringConvertible {
    var photo: String
    var fields: [(id: String, now: String, expected: String)]

    var description: String {
        let list = fields.map { "\(SettingsFields.label($0.id))(今 \($0.now)、この変更の直後 \($0.expected))" }
            .joined(separator: "、")
        return "\(photo) は、この変更の後に別の操作で \(list) が変えられています。"
            + "取り消すとその変更が消えるので、取り消しませんでした。人に確認するか、adjust で必要な項目だけを直してください"
    }
}
