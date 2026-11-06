import Foundation

/// Messages API のストリーミング（SSE）で使うイベント。
enum ClaudeStreamEvent: Equatable, Sendable {
    case messageStart
    case textDelta(index: Int, text: String)
    /// tool_use の block が始まった。入力は inputJSONDelta で少しずつ届く。
    case toolUseStart(index: Int, id: String, name: String)
    case inputJSONDelta(index: Int, partialJSON: String)
    /// Anthropic 側で動くツール（web_search）が始まった。入力（検索の言葉）は inputJSONDelta で届く。
    case serverToolUseStart(index: Int, id: String, name: String)
    /// 検索の結果。失敗も 200 で届くので、失敗のときは `errorCode` が入る。
    case webSearchResult(index: Int, results: [WebSearchTool.Result], errorCode: String?)
    case contentBlockStop(index: Int)
    case messageDelta(stopReason: String?)
    case messageStop
    case ping
    case error(type: String, message: String)
}

/// SSE を1行ずつ読んでイベントにする。
///
/// `URLSession.AsyncBytes.lines` は空行（イベントの区切り）を落とすので、区切りには頼らず
/// `data:` 行ごとに JSON の `type` で判定する（Anthropic のイベントは1イベント1 data 行）。
struct ClaudeStreamParser {
    /// 1行を読み、イベントになれば返す。`event:` 行・コメント・未知のイベントは nil。
    func parse(line: String) -> ClaudeStreamEvent? {
        guard line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        guard let data = payload.data(using: .utf8),
              let raw = try? JSONDecoder().decode(RawEvent.self, from: data)
        else { return nil }

        switch raw.type {
        case "message_start":
            return .messageStart
        case "content_block_start":
            guard let index = raw.index, let block = raw.contentBlock else { return nil }
            if block.type == "tool_use", let id = block.id, let name = block.name {
                return .toolUseStart(index: index, id: id, name: name)
            }
            if block.type == "server_tool_use", let id = block.id, let name = block.name {
                return .serverToolUseStart(index: index, id: id, name: name)
            }
            if block.type == "web_search_tool_result" {
                let parsed = WebSearchTool.parseResult(block.content)
                return .webSearchResult(index: index, results: parsed.results, errorCode: parsed.errorCode)
            }
            // text block の開始時の text は通常空。中身があれば delta として扱う
            if block.type == "text", let text = block.text, !text.isEmpty {
                return .textDelta(index: index, text: text)
            }
            return nil
        case "content_block_delta":
            guard let index = raw.index, let delta = raw.delta else { return nil }
            switch delta.type {
            case "text_delta":
                return delta.text.map { .textDelta(index: index, text: $0) }
            case "input_json_delta":
                return delta.partialJSON.map { .inputJSONDelta(index: index, partialJSON: $0) }
            default:
                return nil
            }
        case "content_block_stop":
            return raw.index.map { .contentBlockStop(index: $0) }
        case "message_delta":
            return .messageDelta(stopReason: raw.delta?.stopReason)
        case "message_stop":
            return .messageStop
        case "ping":
            return .ping
        case "error":
            return .error(type: raw.error?.type ?? "unknown", message: raw.error?.message ?? "")
        default:
            return nil
        }
    }

    private struct RawEvent: Decodable {
        let type: String
        let index: Int?
        let contentBlock: Block?
        let delta: Delta?
        let error: APIError?

        enum CodingKeys: String, CodingKey {
            case type, index, delta, error
            case contentBlock = "content_block"
        }
    }

    private struct Block: Decodable {
        let type: String
        let id: String?
        let name: String?
        let text: String?
        let content: JSONValue?
    }

    private struct Delta: Decodable {
        let type: String?
        let text: String?
        let partialJSON: String?
        let stopReason: String?

        enum CodingKeys: String, CodingKey {
            case type, text
            case partialJSON = "partial_json"
            case stopReason = "stop_reason"
        }
    }

    private struct APIError: Decodable {
        let type: String?
        let message: String?
    }
}
