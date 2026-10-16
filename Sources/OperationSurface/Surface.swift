import Foundation

/// 権限の決まり: 影響の段階ごとに、許す・確認する・拒否する
public struct EffectPolicy: Sendable {
    public enum Decision: Equatable, Sendable { case allow, confirm, deny }

    public var decisions: [Effect: Decision]

    public init(_ decisions: [Effect: Decision]) {
        self.decisions = decisions
    }

    public func decision(for effect: Effect) -> Decision {
        decisions[effect] ?? .deny
    }

    /// AI の既定: 読む・案を作る・取り消せる変更は許す。ファイルを書くのは人の確認が要る。消すのは拒否
    public static let agentDefault = EffectPolicy([
        .read: .allow, .propose: .allow, .modify: .allow, .writeFiles: .confirm, .destructive: .deny,
    ])
    /// 読むだけ
    public static let readOnly = EffectPolicy([.read: .allow, .propose: .allow])
    /// すべて許す(人が直接操作するとき、テスト)
    public static let allowAll = EffectPolicy(Dictionary(uniqueKeysWithValues: Effect.allCases.map { ($0, .allow) }))
}

/// 監査ログの 1 件: 誰が・いつ・どの道具を・どんな引数で呼び・どうなったか
public struct AuditEntry: Sendable {
    public enum Outcome: String, Sendable {
        case succeeded, failed, invalidArguments, denied, unknownTool
    }

    public var sequence: Int
    public var date: Date
    public var caller: Caller
    public var tool: String
    public var arguments: JSONValue
    public var effect: Effect?
    public var outcome: Outcome
    public var summary: String
    public var durationMs: Int
    /// 取り消せる取引を作ったか
    public var undoable: Bool
}

/// 操作面。ソフトが自分の道具を登録し、AI(や他の利用者)はここを通して道具を呼ぶ。
/// 呼び出しのたびに「入力の検証 → 権限の判断 → 実行 → 監査ログ」を行い、取り消しの履歴を持つ。
///
/// スレッドについての約束: 1 つのスレッド(または直列のキュー)からだけ使うこと。
/// 道具の処理がスレッドセーフでない資源(Rawgenzo の RAWSource など)に触ることがあるため、操作面の側では並行に呼ばない
public final class Surface {
    public let name: String
    public let version: String
    /// AI への最初の説明(このソフトで何ができるか、道具の使い方の方針)
    public var instructions: String

    private var tools: [String: Tool] = [:]
    /// 登録順(道具の一覧を毎回同じ順で返す。AI 側のプロンプトキャッシュを効かせるため)
    private var order: [String] = []

    /// 主体ごとの権限。登録が無い主体には defaultPolicy を使う
    public var policies: [Caller: EffectPolicy] = [:]
    public var defaultPolicy: EffectPolicy = .agentDefault
    /// 「確認する」になった呼び出しを人に確かめる手段。nil なら確認できないので拒否する
    public var confirm: ((Caller, ToolDescriptor, JSONValue) -> Bool)?

    public private(set) var auditLog: [AuditEntry] = []
    /// 監査ログを残す件数(古いものから捨てる)
    public var auditLimit = 1000
    /// 監査ログを外に書き出す先(ファイルなど)。1 件ごとに呼ぶ
    public var auditSink: ((AuditEntry) -> Void)?
    private var nextSequence = 1

    private struct Transaction {
        var caller: Caller
        var tool: String
        var actions: [UndoStep]
        var resources: Set<String> { Set(actions.map(\.resource)) }
    }
    private var undoStack: [Transaction] = []
    /// 取り消しの履歴を残す件数
    public var undoLimit = 200

    public init(name: String, version: String, instructions: String = "") {
        self.name = name
        self.version = version
        self.instructions = instructions
    }

    // MARK: - 道具の登録

    public func register(_ tool: Tool) {
        let name = tool.descriptor.name
        precondition(tools[name] == nil, "道具の名前が重なっています: \(name)")
        tools[name] = tool
        order.append(name)
    }

    public func register(_ descriptor: ToolDescriptor,
                         handler: @escaping (JSONValue, ToolContext) throws -> ToolResult) {
        register(Tool(descriptor, handler: handler))
    }

    /// 道具の一覧(登録順)
    public var descriptors: [ToolDescriptor] { order.compactMap { tools[$0]?.descriptor } }

    /// この主体に見せる道具の一覧(拒否される道具は見せない。AI が呼べない道具で迷わないように)
    public func descriptors(for caller: Caller) -> [ToolDescriptor] {
        let policy = policy(for: caller)
        return descriptors.filter { policy.decision(for: $0.effect) != .deny }
    }

    public func policy(for caller: Caller) -> EffectPolicy {
        policies[caller] ?? defaultPolicy
    }

    // MARK: - 呼び出し

    /// 道具を呼ぶ。失敗も ToolResult(isError)で返す(例外は投げない)
    public func call(_ name: String, arguments: JSONValue = .object([:]), as caller: Caller) -> ToolResult {
        let start = Date()
        let args = arguments.isNull ? JSONValue.object([:]) : arguments

        func finish(_ result: ToolResult, _ outcome: AuditEntry.Outcome, effect: Effect?, undoable: Bool = false) -> ToolResult {
            record(AuditEntry(sequence: 0, date: start, caller: caller, tool: name, arguments: args,
                              effect: effect, outcome: outcome, summary: result.summary,
                              durationMs: Int(Date().timeIntervalSince(start) * 1000), undoable: undoable))
            return result
        }

        guard let tool = tools[name] else {
            let names = order.joined(separator: ", ")
            return finish(.error("未知の道具です: \(name)(使える道具: \(names))"), .unknownTool, effect: nil)
        }
        let d = tool.descriptor

        let errors = d.input.validate(args)
        if !errors.isEmpty {
            return finish(.error("引数が正しくありません:\n" + errors.joined(separator: "\n")),
                          .invalidArguments, effect: d.effect)
        }

        switch policy(for: caller).decision(for: d.effect) {
        case .allow:
            break
        case .confirm:
            guard let confirm, confirm(caller, d, args) else {
                return finish(.error("「\(d.title)」は\(d.effect.label)ので人の確認が必要ですが、承認されませんでした"),
                              .denied, effect: d.effect)
            }
        case .deny:
            return finish(.error("「\(d.title)」は\(d.effect.label)ので、この主体には許可されていません"),
                          .denied, effect: d.effect)
        }

        let context = ToolContext(caller: caller, descriptor: d)
        do {
            let result = try tool.handler(args, context)
            if result.isError {
                rollBack(context)
                return finish(result, .failed, effect: d.effect)
            }
            let undoable = !context.undoActions.isEmpty
            if undoable {
                undoStack.append(Transaction(caller: caller, tool: name, actions: context.undoActions))
                if undoStack.count > undoLimit { undoStack.removeFirst(undoStack.count - undoLimit) }
            }
            return finish(result, .succeeded, effect: d.effect, undoable: undoable)
        } catch {
            rollBack(context)
            return finish(.error("「\(d.title)」に失敗しました: \(error)"), .failed, effect: d.effect)
        }
    }

    /// 途中で失敗した呼び出しの変更を、その場で元に戻す
    private func rollBack(_ context: ToolContext) {
        for step in context.undoActions.reversed() { try? step.action() }
    }

    private func record(_ entry: AuditEntry) {
        var e = entry
        e.sequence = nextSequence
        nextSequence += 1
        auditLog.append(e)
        if auditLog.count > auditLimit { auditLog.removeFirst(auditLog.count - auditLimit) }
        auditSink?(e)
    }

    // MARK: - 取り消し

    public enum UndoError: Error, CustomStringConvertible {
        /// 後から別の主体が同じものを変えている
        case conflict(resource: String, laterCaller: Caller)

        public var description: String {
            switch self {
            case .conflict(let r, let c):
                return "後から \(c) が同じ対象(\(r))を変更しているので取り消せません"
            }
        }
    }

    /// この主体が最後に行った取引を取り消す。戻り値は取り消した道具の名前(無ければ nil)。
    /// その取引の後に別の主体が同じ対象を変えていたら UndoError.conflict を投げ、何も変えない
    @discardableResult
    public func undoLast(by caller: Caller) throws -> String? {
        guard let index = undoStack.lastIndex(where: { $0.caller == caller }) else { return nil }
        let t = undoStack[index]
        for later in undoStack[(index + 1)...] where later.caller != caller {
            if let shared = t.resources.intersection(later.resources).sorted().first {
                throw UndoError.conflict(resource: shared, laterCaller: later.caller)
            }
        }
        undoStack.remove(at: index)
        for step in t.actions.reversed() { try step.action() }
        return t.tool
    }

    /// この主体が取り消せる取引の数
    public func undoCount(for caller: Caller) -> Int {
        undoStack.filter { $0.caller == caller }.count
    }

    /// 汎用の道具(取り消し・操作の履歴)を登録する。どのソフトでも同じ形で AI に見せる
    public func registerStandardTools() {
        register(ToolDescriptor(
            name: "undo", title: "取り消す",
            description: "自分が最後に行った変更を 1 つ取り消す。1 回の道具の呼び出しで行った変更はまとめて取り消される。"
                + "人や他のエージェントの変更は取り消さない",
            effect: .modify)) { [unowned self] _, context in
            let undone: String?
            do { undone = try self.undoLast(by: context.caller) } catch { return .error("\(error)") }
            guard let tool = undone else { return .error("取り消せる変更がありません") }
            return .text("「\(self.tools[tool]?.descriptor.title ?? tool)」の変更を取り消しました(残り \(self.undoCount(for: context.caller)) 件)")
        }
        register(ToolDescriptor(
            name: "recent_operations", title: "操作の履歴",
            description: "このソフトで行われた最近の操作(誰が・どの道具を・結果)を新しい順に返す",
            input: .object([.init("limit", .integer("返す件数(既定 20)", minimum: 1, maximum: 200))]),
            effect: .read)) { [unowned self] args, _ in
            let limit = args["limit"]?.intValue ?? 20
            let entries = self.auditLog.suffix(limit).reversed().map { e -> JSONValue in
                [
                    "seq": .number(Double(e.sequence)),
                    "caller": .string(e.caller.description),
                    "tool": .string(e.tool),
                    "outcome": .string(e.outcome.rawValue),
                    "summary": .string(e.summary),
                ]
            }
            return .json(.array(Array(entries)))
        }
    }
}
