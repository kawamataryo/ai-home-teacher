import Foundation

/// Worker が許可しているモデル（worker/src/upstream.ts の ALLOWED_MODELS と揃える）。
enum ClaudeModel: String, Sendable, Codable {
    case haiku = "claude-haiku-5-5"
    case sonnet = "claude-sonnet-5-5"
    case opus = "claude-opus-5-5"
}

enum ChatRole: String, Sendable, Codable {
    case user
    case assistant
}

/// Messages API の content block。使うものだけを持つ。
enum ContentBlock: Equatable, Sendable, Codable {
    case text(String)
    case toolUse(id: String, name: String, input: JSONValue)
    case toolResult(toolUseID: String, content: String)

    private enum CodingKeys: String, CodingKey {
        case type, text, id, name, input
        case toolUseID = "tool_use_id"
        case content
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "text":
            self = .text(try c.decode(String.self, forKey: .text))
        case "tool_use":
            self = .toolUse(
                id: try c.decode(String.self, forKey: .id),
                name: try c.decode(String.self, forKey: .name),
                input: try c.decode(JSONValue.self, forKey: .input)
            )
        case "tool_result":
            self = .toolResult(
                toolUseID: try c.decode(String.self, forKey: .toolUseID),
                content: try c.decode(String.self, forKey: .content)
            )
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "未対応の type: \(other)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try c.encode("text", forKey: .type)
            try c.encode(text, forKey: .text)
        case .toolUse(let id, let name, let input):
            try c.encode("tool_use", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name)
            try c.encode(input, forKey: .input)
        case .toolResult(let toolUseID, let content):
            try c.encode("tool_result", forKey: .type)
            try c.encode(toolUseID, forKey: .toolUseID)
            try c.encode(content, forKey: .content)
        }
    }
}

struct ChatMessage: Equatable, Sendable, Codable {
    var role: ChatRole
    var content: [ContentBlock]

    /// text block をつなげた文字列（ツールの呼び出しは含まない）。
    var text: String {
        content.compactMap { if case .text(let t) = $0 { t } else { nil } }.joined()
    }
}

/// ツールの定義。`input_schema` は JSON Schema。
struct ToolDefinition: Equatable, Sendable, Codable {
    let name: String
    let description: String
    let inputSchema: JSONValue
    /// strict tool use にするか。nil なら送らない（prompts/tools/*.json は書いていない）
    var strict: Bool? = nil

    private enum CodingKeys: String, CodingKey {
        case name, description, strict
        case inputSchema = "input_schema"
    }
}

/// `POST /v1/claude` の本文（= Anthropic Messages API）。
struct MessagesRequest: Equatable, Sendable, Encodable {
    let model: ClaudeModel
    let maxTokens: Int
    let system: String
    let messages: [ChatMessage]
    let stream: Bool
    var tools: [ToolDefinition]? = nil
    /// 拡張思考の設定。会話では `{"type":"disabled"}` にする（下の `thinkingDisabled`）。
    var thinking: JSONValue? = nil

    /// 会話（Haiku）では考える処理を止める。止めないと、返事の前に 250〜350 トークン考えて
    /// 最初の一文までが約 2 倍遅くなり（実測 2.1 秒 → 1.1 秒）、max_tokens を考える部分で使い切ると返事が空になる。
    static let thinkingDisabled: JSONValue = .object(["type": .string("disabled")])

    private enum CodingKeys: String, CodingKey {
        case model, system, messages, stream, tools, thinking
        case maxTokens = "max_tokens"
    }
}
