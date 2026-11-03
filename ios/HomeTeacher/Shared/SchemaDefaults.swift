import Foundation

/// strict ではないツールの入力を、JSON Schema（`Schema` で作ったもの）に合わせて直す。
///
/// - 足りないキーは既定値で埋める（文字 → ""、数 → 0、真偽 → false、配列 → []、オブジェクト → 中身を既定値で）
/// - 型が違う値は、読めれば直す（"12" → 12、12 → "12"）。読めなければ既定値にする
/// - `anyOf` は、値の `type` と同じ `const` を持つ枝に合わせる。どれとも合わなければそのまま返す
/// - スキーマにないキーは残す（Decodable は無視する）
enum SchemaDefaults {
    static func fill(_ value: JSONValue?, schema: JSONValue) -> JSONValue {
        if case .array(let branches)? = schema["anyOf"] {
            return fillAnyOf(value, branches: branches)
        }
        if let constant = schema["const"] { return constant }
        switch schema["type"]?.stringValue {
        case "object":
            guard case .object(let properties)? = schema["properties"] else { return value ?? .object([:]) }
            var out: [String: JSONValue] = [:]
            if case .object(let existing)? = value { out = existing }
            for (key, propertySchema) in properties {
                out[key] = fill(out[key], schema: propertySchema)
            }
            return .object(out)
        case "array":
            guard case .array(let items)? = value else { return .array([]) }
            guard let itemSchema = schema["items"] else { return .array(items) }
            return .array(items.map { fill($0, schema: itemSchema) })
        case "string":
            switch value {
            case .string(let s): return .string(s)
            case .number(let n): return .string(n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n))
            case .bool(let b): return .string(b ? "true" : "false")
            default: return .string("")
            }
        case "number", "integer":
            switch value {
            case .number(let n): return .number(n)
            case .string(let s):
                return .number(Double(s.trimmingCharacters(in: .whitespaces)) ?? 0)
            default: return .number(0)
            }
        case "boolean":
            if case .bool(let b)? = value { return .bool(b) }
            if case .string(let s)? = value { return .bool(s == "true") }
            return .bool(false)
        default:
            return value ?? .null
        }
    }

    private static func fillAnyOf(_ value: JSONValue?, branches: [JSONValue]) -> JSONValue {
        guard let value else { return .null }
        let tag = value["type"]?.stringValue
        guard let branch = branches.first(where: { $0["properties"]?["type"]?["const"]?.stringValue == tag }) else {
            return value
        }
        return fill(value, schema: branch)
    }
}
