import Foundation

/// 先生と子どもの会話履歴。Haiku と Sonnet で共有する（spec §4）。
struct ConversationHistory: Equatable, Sendable {
    private(set) var messages: [ChatMessage] = []

    /// 子どもの発話を足す。
    mutating func appendUser(_ text: String) {
        append(.user, .text(text))
    }

    /// 先生の発話をストリーミングで少しずつ足す。直前が先生の発言ならそこにつなげる。
    mutating func appendAssistantText(_ text: String) {
        guard !text.isEmpty else { return }
        if var last = messages.last, last.role == .assistant {
            if case .text(let existing) = last.content.last {
                last.content[last.content.count - 1] = .text(existing + text)
            } else {
                last.content.append(.text(text))
            }
            messages[messages.count - 1] = last
        } else {
            messages.append(ChatMessage(role: .assistant, content: [.text(text)]))
        }
    }

    /// 任意の block を足す（ツールの呼び出し・結果など）。同じ役割が続くときは1つのメッセージにまとめる。
    mutating func append(_ role: ChatRole, _ block: ContentBlock) {
        if var last = messages.last, last.role == role {
            last.content.append(block)
            messages[messages.count - 1] = last
        } else {
            messages.append(ChatMessage(role: role, content: [block]))
        }
    }

    /// 最後の返事の始まり（最後の子どもの発話の次のメッセージ）。子どもの発話がなければ先頭
    ///
    /// 図を出した返事は「先生の文と tool_use」→「tool_result（user）」→「続きの文」と複数のメッセージになる。
    /// tool_result だけの user メッセージは子どもの発話ではないので、返事の途中とみなす。
    private var lastReplyStart: Int {
        let lastUtterance = messages.lastIndex { message in
            message.role == .user && message.content.contains { if case .text = $0 { true } else { false } }
        }
        return lastUtterance.map { $0 + 1 } ?? 0
    }

    /// 最後の返事で先生が話した文字（図をはさんだ前後の文をつなげたもの。ツールの呼び出しは含まない）。
    /// まだ 1 文字も届いていなければ空
    var lastReplyText: String {
        messages[lastReplyStart...].filter { $0.role == .assistant }.map(\.text).joined()
    }

    /// 割り込み用：最後の返事を、実際に再生した位置（`lastReplyText` の `Character` の数）で切り詰める（#13, #86）。
    ///
    /// 図の前の文・続きの文をまたいで、先頭から数える。ツールの呼び出しと結果は残す（API は tool_use と
    /// tool_result が対になっていないと受け付けない）。text が空になった block は消し、メッセージが空になったら
    /// メッセージごと消す（API は空の text を受け付けない）。前後の同じ役割のメッセージはまとめ直す。
    mutating func truncateLastReply(toCharacterCount count: Int) {
        var remaining = max(0, count)
        var index = lastReplyStart
        while index < messages.count {
            guard messages[index].role == .assistant else {
                index += 1
                continue
            }
            var blocks: [ContentBlock] = []
            for block in messages[index].content {
                guard case .text(let text) = block else {
                    blocks.append(block)
                    continue
                }
                let kept = String(text.prefix(remaining))
                remaining -= kept.count
                if !kept.isEmpty { blocks.append(.text(kept)) }
            }
            if blocks.isEmpty {
                messages.remove(at: index)
            } else {
                messages[index].content = blocks
                index += 1
            }
        }
        mergeAdjacentSameRole()
    }

    /// 最後の返事のツールの結果を書き換える（対は崩さない）。`transform` はツールの名前と今の結果を受け取る
    mutating func rewriteLastReplyToolResults(_ transform: (_ toolName: String, _ content: String) -> String) {
        let start = lastReplyStart
        var names: [String: String] = [:]
        for message in messages[start...] where message.role == .assistant {
            for case .toolUse(let id, let name, _) in message.content { names[id] = name }
        }
        for index in messages.indices where index >= start && messages[index].role == .user {
            messages[index].content = messages[index].content.map { block in
                guard case .toolResult(let id, let content) = block, let name = names[id] else { return block }
                return .toolResult(toolUseID: id, content: transform(name, content))
            }
        }
    }

    /// 最後の先生の発言（text のみ）。
    var lastAssistantText: String? {
        messages.last(where: { $0.role == .assistant })?.text
    }

    mutating func removeAll() {
        messages.removeAll()
    }

    private mutating func mergeAdjacentSameRole() {
        var merged: [ChatMessage] = []
        for message in messages {
            if var last = merged.last, last.role == message.role {
                last.content += message.content
                merged[merged.count - 1] = last
            } else {
                merged.append(message)
            }
        }
        messages = merged
    }
}
