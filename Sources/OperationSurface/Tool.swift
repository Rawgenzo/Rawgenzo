import Foundation

/// 道具を呼んだときにソフトに及ぶ影響の段階。権限の判断と、AI への説明に使う。
/// 段階は小さいほど安全(Comparable の順)
public enum Effect: Int, Comparable, CaseIterable, Sendable {
    /// 読むだけ。何も変えない
    case read
    /// 案を作るだけ。確定しない(試しに現像して見せる、など)
    case propose
    /// ソフトの状態を変える。取り消せる
    case modify
    /// ファイルを書く(書き出しなど)。取り消せない
    case writeFiles
    /// 消す・上書きして戻せなくする
    case destructive

    public static func < (a: Effect, b: Effect) -> Bool { a.rawValue < b.rawValue }

    public var name: String {
        switch self {
        case .read: return "read"
        case .propose: return "propose"
        case .modify: return "modify"
        case .writeFiles: return "writeFiles"
        case .destructive: return "destructive"
        }
    }

    public var label: String {
        switch self {
        case .read: return "読むだけ"
        case .propose: return "案を作るだけ(確定しない)"
        case .modify: return "状態を変える(取り消せる)"
        case .writeFiles: return "ファイルを書く(取り消せない)"
        case .destructive: return "消す(取り消せない)"
        }
    }
}

/// 道具の記述。AI に渡す道具の一覧(MCP の tools/list、各社 API の tools)はこれから作る
public struct ToolDescriptor: Sendable {
    /// 道具の名前。英小文字・数字・_ だけにする(各社 API の名前の決まりに合わせる)
    public var name: String
    /// 人が読む短い名前
    public var title: String
    /// 何をする道具か。いつ使うか・使う前に何を確かめるか・費用(画像を返すなど)もここに書く
    public var description: String
    public var input: JSONSchema
    public var effect: Effect

    public init(name: String, title: String, description: String,
                input: JSONSchema = .object([]), effect: Effect) {
        precondition(name.range(of: "^[a-z][a-z0-9_]{0,63}$", options: .regularExpression) != nil,
                     "道具の名前は英小文字で始まる英小文字・数字・_ にする: \(name)")
        precondition(input.kind == .object, "道具の入力は object にする: \(name)")
        self.name = name; self.title = title; self.description = description
        self.input = input; self.effect = effect
    }
}

/// 道具の結果の中身
public enum ToolContent: Equatable, Sendable {
    case text(String)
    /// 構造のある結果。AI には JSON の文字列として渡す
    case json(JSONValue)
    /// 画像。トークンを多く使うので、必要なときだけ返す
    case image(data: Data, mimeType: String)
}

public struct ToolResult: Equatable, Sendable {
    public var content: [ToolContent]
    /// 失敗を表す結果(AI に「失敗した理由」を読ませて、やり直させるため。例外ではなく結果として返す)
    public var isError: Bool

    public init(_ content: [ToolContent], isError: Bool = false) {
        self.content = content
        self.isError = isError
    }

    public static func text(_ s: String) -> ToolResult { ToolResult([.text(s)]) }
    public static func json(_ v: JSONValue) -> ToolResult { ToolResult([.json(v)]) }
    public static func error(_ s: String) -> ToolResult { ToolResult([.text(s)], isError: true) }

    /// 監査ログ用の短い要約(画像は大きさだけ)
    public var summary: String {
        content.map { c -> String in
            switch c {
            case .text(let s): return s.count > 200 ? String(s.prefix(200)) + "…" : s
            case .json(let v):
                let s = v.jsonString()
                return s.count > 200 ? String(s.prefix(200)) + "…" : s
            case .image(let data, let mime): return "[\(mime) \(data.count) バイト]"
            }
        }.joined(separator: " / ")
    }
}

/// 操作する主体。監査ログに残し、取り消しは主体ごとに行う(AI が人の操作を取り消さないように)
public struct Caller: Hashable, Sendable, CustomStringConvertible {
    public enum Kind: String, Sendable { case human, agent }
    public var id: String
    public var kind: Kind

    public init(id: String, kind: Kind) {
        self.id = id; self.kind = kind
    }

    public static func agent(_ id: String) -> Caller { Caller(id: id, kind: .agent) }
    public static func human(_ id: String) -> Caller { Caller(id: id, kind: .human) }

    public var description: String { "\(kind.rawValue):\(id)" }
}

/// 道具の処理に渡す文脈。取り消しの手順はここに登録する
public final class ToolContext {
    public let caller: Caller
    public let descriptor: ToolDescriptor
    /// 呼び出しに付いた作業名(状態を変える道具のとき)
    public let task: String?
    var undoActions: [UndoStep] = []

    init(caller: Caller, descriptor: ToolDescriptor, task: String? = nil) {
        self.caller = caller
        self.descriptor = descriptor
        self.task = task
    }

    /// 状態を変えたら、元に戻す手順を登録する。label は取り消しを断るときなどに AI へ見せる名前(例「DSC03561.ARW の設定」)。1 回の呼び出しで登録したものは 1 つの取引としてまとめて取り消す
    /// (登録の逆順に実行する)。処理の途中で失敗したときは、それまでに登録した手順でその場で元に戻す。
    /// - resource: 変えたものの識別子(写真のパスなど)。後から別の主体が同じものを変えていたら取り消しを断る。
    ///   取り消しは「変える前の値に戻す」なので、断らないと後から入った人の変更まで消してしまうため
    public func registerUndo(_ label: String, resource: String, _ action: @escaping () throws -> Void) {
        undoActions.append(UndoStep(label: label, resource: resource, action: action))
    }
}

struct UndoStep {
    var label: String
    var resource: String
    var action: () throws -> Void
}

/// 道具。記述と処理の組
public struct Tool {
    public var descriptor: ToolDescriptor
    /// 入力はスキーマで検証済みのものが渡る。失敗は ToolResult.error を返すか、例外を投げる(例外の説明が AI に渡る)
    public var handler: (JSONValue, ToolContext) throws -> ToolResult

    public init(_ descriptor: ToolDescriptor, handler: @escaping (JSONValue, ToolContext) throws -> ToolResult) {
        self.descriptor = descriptor
        self.handler = handler
    }
}
