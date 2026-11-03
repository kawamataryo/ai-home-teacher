import Foundation

/// ストリーミングで少しずつ届く tool_use の入力（partial_json）を、block ごとにためて組み立てる。
struct ToolUseAccumulator {
    struct ToolUse: Equatable, Sendable {
        let id: String
        let name: String
        let input: JSONValue
    }

    private var pending: [Int: (id: String, name: String, json: String)] = [:]

    mutating func start(index: Int, id: String, name: String) {
        pending[index] = (id, name, "")
    }

    mutating func append(index: Int, partialJSON: String) {
        pending[index]?.json += partialJSON
    }

    /// block の終わり。tool_use の block なら組み立てて返す（text の block なら nil）。
    /// 入力が空なら `{}`、JSON として読めなければ `{}` として返す（tool_result は必ず返す必要があるため）。
    mutating func stop(index: Int) -> ToolUse? {
        guard let entry = pending.removeValue(forKey: index) else { return nil }
        let json = entry.json.trimmingCharacters(in: .whitespacesAndNewlines)
        let input = json.isEmpty
            ? JSONValue.object([:])
            : (try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))) ?? .object([:])
        return ToolUse(id: entry.id, name: entry.name, input: input)
    }
}
