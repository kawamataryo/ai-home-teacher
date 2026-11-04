import Foundation

/// 任意の JSON。ツール定義（JSON Schema）の組み立てと、tool_use の入力の受け取りに使う。
enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    /// キー順を固定した JSON（プロンプトキャッシュが壊れないよう、毎回同じバイト列にする）。
    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    var jsonString: String {
        (try? jsonData()).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
}

/// strict tool use 用の JSON Schema を組み立てる小さな DSL。
/// strict では全オブジェクトに `additionalProperties: false` と全キーの `required` が要るので、ここで必ず付ける。
/// 数値や文字数の制約（minimum など）は strict 非対応なので使わない。
enum Schema {
    /// `required` を渡さなければ、全部のキーを必須にする（strict のツールは全部必須でないと通らない）
    static func object(_ properties: [(String, JSONValue)], required: [String]? = nil, description: String? = nil) -> JSONValue {
        var o: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(Dictionary(uniqueKeysWithValues: properties)),
            "required": .array((required ?? properties.map(\.0)).map { .string($0) }),
            "additionalProperties": .bool(false),
        ]
        if let description { o["description"] = .string(description) }
        return .object(o)
    }

    static func string(_ description: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(description)])
    }

    static func number(_ description: String) -> JSONValue {
        .object(["type": .string("number"), "description": .string(description)])
    }

    static func integer(_ description: String) -> JSONValue {
        .object(["type": .string("integer"), "description": .string(description)])
    }

    static func boolean(_ description: String) -> JSONValue {
        .object(["type": .string("boolean"), "description": .string(description)])
    }

    static func array(_ items: JSONValue, description: String) -> JSONValue {
        .object(["type": .string("array"), "items": items, "description": .string(description)])
    }

    static func constant(_ value: String) -> JSONValue {
        .object(["type": .string("string"), "const": .string(value)])
    }

    static func anyOf(_ schemas: [JSONValue], description: String) -> JSONValue {
        .object(["anyOf": .array(schemas), "description": .string(description)])
    }
}
