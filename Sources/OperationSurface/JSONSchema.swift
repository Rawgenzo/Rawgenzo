import Foundation

/// 道具の入力の形。JSON Schema の、道具の引数に要る分だけの部分集合。
/// AI に渡す説明(MCP の inputSchema、各社 API の tools)と、呼ばれたときの入力の検証の両方に使う。
///
/// 範囲(minimum / maximum)は検証で外れたら拒否する。範囲を丸めて受け入れたい値は、
/// スキーマには範囲を書かず説明文に書き、道具の側で丸めて結果で知らせること
public struct JSONSchema: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case object, number, integer, string, boolean, array
    }

    public struct Property: Equatable, Sendable {
        public var name: String
        public var schema: JSONSchema
        public init(_ name: String, _ schema: JSONSchema) {
            self.name = name; self.schema = schema
        }
    }

    public var kind: Kind
    public var description: String?
    /// null も受け付ける(「未指定に戻す」を表すときなど)
    public var nullable = false
    // object
    public var properties: [Property] = []
    public var required: [String] = []
    // number / integer
    public var minimum: Double?
    public var maximum: Double?
    // string
    public var enumValues: [String]?
    // array(要素の形は 0 個か 1 個。構造体を自分自身で入れ子にできないので配列で持つ)
    private var itemSchemas: [JSONSchema] = []
    public var minItems: Int?
    public var maxItems: Int?

    public var items: JSONSchema? { itemSchemas.first }

    public init(kind: Kind, description: String? = nil) {
        self.kind = kind
        self.description = description
    }

    // MARK: - 組み立て

    public static func object(_ properties: [Property], required: [String] = [],
                              description: String? = nil) -> JSONSchema {
        var s = JSONSchema(kind: .object, description: description)
        s.properties = properties
        s.required = required
        return s
    }

    public static func number(_ description: String? = nil, minimum: Double? = nil, maximum: Double? = nil) -> JSONSchema {
        var s = JSONSchema(kind: .number, description: description)
        s.minimum = minimum; s.maximum = maximum
        return s
    }

    public static func integer(_ description: String? = nil, minimum: Double? = nil, maximum: Double? = nil) -> JSONSchema {
        var s = JSONSchema(kind: .integer, description: description)
        s.minimum = minimum; s.maximum = maximum
        return s
    }

    public static func string(_ description: String? = nil, oneOf values: [String]? = nil) -> JSONSchema {
        var s = JSONSchema(kind: .string, description: description)
        s.enumValues = values
        return s
    }

    public static func boolean(_ description: String? = nil) -> JSONSchema {
        JSONSchema(kind: .boolean, description: description)
    }

    public static func array(of item: JSONSchema, description: String? = nil,
                             minItems: Int? = nil, maxItems: Int? = nil) -> JSONSchema {
        var s = JSONSchema(kind: .array, description: description)
        s.itemSchemas = [item]
        s.minItems = minItems; s.maxItems = maxItems
        return s
    }

    /// null も受け付けるようにした写し
    public func orNull() -> JSONSchema {
        var s = self
        s.nullable = true
        return s
    }

    // MARK: - JSON Schema として書き出す

    public func toJSON() -> JSONValue {
        var o: [String: JSONValue] = [:]
        o["type"] = nullable ? .array([.string(kind.rawValue), "null"]) : .string(kind.rawValue)
        if let description { o["description"] = .string(description) }
        switch kind {
        case .object:
            o["properties"] = .object(Dictionary(uniqueKeysWithValues: properties.map { ($0.name, $0.schema.toJSON()) }))
            if !required.isEmpty { o["required"] = .array(required.map { .string($0) }) }
            o["additionalProperties"] = false
        case .number, .integer:
            if let minimum { o["minimum"] = .number(minimum) }
            if let maximum { o["maximum"] = .number(maximum) }
        case .string:
            if let enumValues { o["enum"] = .array(enumValues.map { .string($0) }) }
        case .array:
            if let items { o["items"] = items.toJSON() }
            if let minItems { o["minItems"] = .number(Double(minItems)) }
            if let maxItems { o["maxItems"] = .number(Double(maxItems)) }
        case .boolean:
            break
        }
        return .object(o)
    }

    // MARK: - 検証

    /// 値がこの形に合うか調べ、合わない点を説明の文で返す(空なら合っている)。
    /// path は値の場所(例 "$.changes.exposure")。AI がどこを直せばよいか分かるように付ける
    public func validate(_ value: JSONValue, path: String = "$") -> [String] {
        if value.isNull {
            return nullable ? [] : ["\(path): null は使えません(\(kind.rawValue) が必要)"]
        }
        switch (kind, value) {
        case (.object, .object(let o)):
            var errors: [String] = []
            for name in required where o[name] == nil {
                errors.append("\(path).\(name): 必須の項目がありません")
            }
            let known = Dictionary(uniqueKeysWithValues: properties.map { ($0.name, $0.schema) })
            for (key, v) in o.sorted(by: { $0.key < $1.key }) {
                if let schema = known[key] {
                    errors += schema.validate(v, path: "\(path).\(key)")
                } else {
                    let names = properties.map(\.name).joined(separator: ", ")
                    errors.append("\(path).\(key): 未知の項目です(使える項目: \(names))")
                }
            }
            return errors
        case (.number, .number(let n)), (.integer, .number(let n)):
            guard n.isFinite else { return ["\(path): 有限の数値が必要です"] }
            if kind == .integer, n.rounded() != n { return ["\(path): 整数が必要です(\(n))"] }
            if let minimum, n < minimum { return ["\(path): \(n) は最小値 \(minimum) より小さい"] }
            if let maximum, n > maximum { return ["\(path): \(n) は最大値 \(maximum) より大きい"] }
            return []
        case (.string, .string(let s)):
            if let enumValues, !enumValues.contains(s) {
                return ["\(path): \"\(s)\" は使えません(\(enumValues.joined(separator: " / ")) のどれか)"]
            }
            return []
        case (.boolean, .bool):
            return []
        case (.array, .array(let a)):
            var errors: [String] = []
            if let minItems, a.count < minItems { errors.append("\(path): 要素が \(minItems) 個以上必要です") }
            if let maxItems, a.count > maxItems { errors.append("\(path): 要素は \(maxItems) 個までです") }
            if let items {
                for (i, v) in a.enumerated() { errors += items.validate(v, path: "\(path)[\(i)]") }
            }
            return errors
        default:
            return ["\(path): \(kind.rawValue) が必要です(\(value.typeName) が渡されました)"]
        }
    }
}
