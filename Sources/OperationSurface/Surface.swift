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
    /// 作業名(状態を変える呼び出しに AI が付ける。人の 1 つの指示のまとまり)
    public var task: String?
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

    /// どのソフトでも同じ、操作のしかたの決まり(作業名と取り消し、頼まれていないことをしない)。
    /// registerStandardTools() を呼んだとき、AI への説明(fullInstructions)に付け足す
    public static let standardGuidance = """
        操作の決まり:
        - 状態を変える道具には task(作業名)を付けられる。人の 1 つの指示のために何回か変更するときは、
          すべての呼び出しに同じ task(その指示を短く表す名前。例「明るさを揃える」)を付ける。
          undo は最後の作業(同じ task の変更すべて)をまとめて取り消す。task の無い変更は 1 回の呼び出しごとに取り消す
        - 頼まれていない項目は変えない。目標に届かないときは、別の項目で無理に合わせず、結果を人に伝えて判断を仰ぐ
        """

    /// AI に渡す説明の全体(ソフトの説明 + 汎用の決まり)
    public var fullInstructions: String {
        guard hasStandardTools else { return instructions }
        return instructions.isEmpty ? Self.standardGuidance : instructions + "\n\n" + Self.standardGuidance
    }
    private var hasStandardTools = false

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
        var task: String?
        var actions: [UndoStep]
        /// 手順を持たない記録(noteChange)の対象
        var notedResources: Set<String> = []
        var resources: Set<String> { Set(actions.map(\.resource)).union(notedResources) }
        var isUndoable: Bool { !actions.isEmpty }
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

    /// 作業名(task)の引数を自動で足した道具。この道具の処理には task を渡さない
    private var taskTools: Set<String> = []

    /// 道具を登録する。状態を変える道具(modify 以上)には、作業名の引数 task を自動で足す
    public func register(_ tool: Tool) {
        var tool = tool
        let name = tool.descriptor.name
        precondition(tools[name] == nil, "道具の名前が重なっています: \(name)")
        if tool.descriptor.effect >= .modify, !tool.descriptor.input.properties.contains(where: { $0.name == "task" }) {
            tool.descriptor.input.properties.append(.init("task", .string(Self.taskDescription)))
            taskTools.insert(name)
        }
        tools[name] = tool
        order.append(name)
    }

    static let taskDescription = "作業名。人の 1 つの指示のために何回か変更するときは、同じ作業名を付ける(undo でまとめて取り消せる)"

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

        let task = taskTools.contains(name) ? args["task"]?.stringValue : nil

        func finish(_ result: ToolResult, _ outcome: AuditEntry.Outcome, effect: Effect?, undoable: Bool = false) -> ToolResult {
            record(AuditEntry(sequence: 0, date: start, caller: caller, tool: name, arguments: args,
                              effect: effect, task: task, outcome: outcome, summary: result.summary,
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

        let context = ToolContext(caller: caller, descriptor: d, task: task)
        // 作業名は操作面が扱うので、道具の処理には渡さない
        var handlerArgs = args
        if taskTools.contains(name), case .object(var o) = args {
            o["task"] = nil
            handlerArgs = .object(o)
        }
        do {
            let result = try tool.handler(handlerArgs, context)
            if result.isError {
                rollBack(context)
                return finish(result, .failed, effect: d.effect)
            }
            let undoable = !context.undoActions.isEmpty
            if undoable {
                undoStack.append(Transaction(caller: caller, tool: name, task: task, actions: context.undoActions))
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
        /// 後から自分の別の作業で同じものを変えている(先にそちらを取り消す必要がある)
        case laterOwnChange(resource: String, task: String?)
        /// その作業名の変更が無い
        case noSuchTask(String)

        public var description: String {
            switch self {
            case .conflict(let r, let c):
                return "後から \(c) が同じ対象(\(r))を変更しているので取り消せません"
            case .laterOwnChange(let r, let task):
                let name = task.map { "作業「\($0)」" } ?? "別の変更"
                return "後から自分の\(name)で同じ対象(\(r))を変更しているので取り消せません。先にそちらを取り消してください"
            case .noSuchTask(let t):
                return "作業「\(t)」の取り消せる変更がありません"
            }
        }
    }

    public struct UndoOutcome: Equatable {
        /// 取り消した取引の数
        public var count: Int
        /// 取り消した作業名(作業名の無い変更なら nil)
        public var task: String?
        /// 取り消した道具の名前(新しい順)
        public var tools: [String]
    }

    /// この主体の最後の作業を取り消す。最後の取引に作業名があれば、同じ作業名の取引をすべて取り消す。
    /// task を渡せば、その作業名の取引をすべて取り消す。何も無ければ nil。
    /// 取り消す取引より後に、取り消さない取引(別の主体・自分の別の作業)が同じ対象を変えていたら、何も変えずに例外を投げる
    /// (取り消しは「変える前の値に戻す」なので、戻すと後の変更まで消えるため)
    @discardableResult
    public func undo(by caller: Caller, task: String? = nil) throws -> UndoOutcome? {
        let mine = undoStack.indices.filter { undoStack[$0].caller == caller && undoStack[$0].isUndoable }
        guard let last = mine.last else {
            if let task { throw UndoError.noSuchTask(task) }
            return nil
        }
        let label = task ?? undoStack[last].task
        let targets = label == nil ? [last] : mine.filter { undoStack[$0].task == label }
        if targets.isEmpty, let task { throw UndoError.noSuchTask(task) }
        let targetSet = Set(targets)
        for i in targets {
            for j in (i + 1)..<undoStack.count where !targetSet.contains(j) {
                let later = undoStack[j]
                if let shared = undoStack[i].resources.intersection(later.resources).sorted().first {
                    // AI に見せるのは対象の識別子(パスなど)ではなく、取り消しの手順に付けた名前
                    let name = undoStack[i].actions.first { $0.resource == shared }?.label ?? shared
                    if later.caller == caller { throw UndoError.laterOwnChange(resource: name, task: later.task) }
                    throw UndoError.conflict(resource: name, laterCaller: later.caller)
                }
            }
        }
        var tools: [String] = []
        for i in targets.sorted(by: >) {
            for step in undoStack[i].actions.reversed() { try step.action() }
            tools.append(undoStack[i].tool)
            undoStack.remove(at: i)
        }
        return UndoOutcome(count: targets.count, task: label, tools: tools)
    }

    /// この主体が最後に行った作業を取り消す(undo(by:task:) の簡易版)。戻り値は最後に取り消した道具の名前
    @discardableResult
    public func undoLast(by caller: Caller) throws -> String? {
        try undo(by: caller)?.tools.first
    }

    /// 操作面を通さずに行われた変更(アプリの画面で人が変えた、など)を記録する。
    /// 取り消しはできない(手順を持たない)が、後から AI が同じ対象の変更を取り消そうとしたときに断る判断に使う
    public func noteChange(by caller: Caller, resource: String, description: String) {
        undoStack.append(Transaction(caller: caller, tool: description, task: nil, actions: [],
                                     notedResources: [resource]))
        if undoStack.count > undoLimit { undoStack.removeFirst(undoStack.count - undoLimit) }
        record(AuditEntry(sequence: 0, date: Date(), caller: caller, tool: description, arguments: ["resource": .string(resource)],
                          effect: .modify, task: nil, outcome: .succeeded, summary: "", durationMs: 0, undoable: false))
    }

    /// この主体が取り消せる取引の数
    public func undoCount(for caller: Caller) -> Int {
        undoStack.filter { $0.caller == caller && $0.isUndoable }.count
    }

    /// 汎用の道具(取り消し・操作の履歴)を登録する。どのソフトでも同じ形で AI に見せる
    public func registerStandardTools() {
        hasStandardTools = true
        register(ToolDescriptor(
            name: "undo", title: "取り消す",
            description: "自分が最後に行った作業を取り消す。作業名(task)の付いた変更は、同じ作業名の変更をまとめて取り消す。"
                + "作業名の無い変更は 1 回の呼び出しの分を取り消す。task を渡すとその作業を取り消す。"
                + "人や他のエージェントの変更は取り消さない",
            input: .object([.init("task", .string("取り消す作業名(省略すると最後の作業)"))]),
            effect: .modify)) { [unowned self] args, context in
            let outcome: UndoOutcome?
            do { outcome = try self.undo(by: context.caller, task: args["task"]?.stringValue) } catch { return .error("\(error)") }
            guard let outcome else { return .error("取り消せる変更がありません") }
            let what = outcome.task.map { "作業「\($0)」の変更 \(outcome.count) 件" }
                ?? "「\(self.tools[outcome.tools[0]]?.descriptor.title ?? outcome.tools[0])」の変更"
            return .text("\(what)を取り消しました(残り \(self.undoCount(for: context.caller)) 件)")
        }
        register(ToolDescriptor(
            name: "recent_operations", title: "操作の履歴",
            description: "このソフトで行われた最近の操作(誰が・どの道具を・どんな引数で・結果)を新しい順に返す。"
                + "読むだけの操作は含めない(include_reads で含める)",
            input: .object([
                .init("limit", .integer("返す件数(既定 10)", minimum: 1, maximum: 200)),
                .init("include_reads", .boolean("読むだけの操作も含めるか(既定 false)")),
            ]),
            effect: .read)) { [unowned self] args, _ in
            let limit = args["limit"]?.intValue ?? 10
            let includeReads = args["include_reads"]?.boolValue ?? false
            func short(_ s: String) -> String { s.count > 120 ? String(s.prefix(120)) + "…" : s }
            let entries = self.auditLog.reversed()
                .filter { includeReads || ($0.effect ?? .read) > .propose }
                .prefix(limit)
                .map { e -> JSONValue in
                    [
                        "seq": .number(Double(e.sequence)),
                        "caller": .string(e.caller.description),
                        "tool": .string(e.tool),
                        "task": e.task.map { .string($0) } ?? .null,
                        "arguments": .string(short(e.arguments.jsonString())),
                        "outcome": .string(e.outcome.rawValue),
                        "undoable": .bool(e.undoable),
                    ]
                }
            return .json(.array(Array(entries)))
        }
    }
}
