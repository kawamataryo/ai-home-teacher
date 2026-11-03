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

    /// 割り込み用：最後の先生の発言を、実際に再生した位置（`Character` の数）で切り詰める。
    ///
    /// ツールの呼び出しは残す。text が空になった block は消し、メッセージが空になったら
    /// メッセージごと消す（API は空の text を受け付けない）。前後の子どもの発話はまとめ直す。
    mutating func truncateLastAssistant(toCharacterCount count: Int) {
        guard let index = messages.lastIndex(where: { $0.role == .assistant }) else { return }
        var remaining = max(0, count)
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
            mergeAdjacentSameRole()
        } else {
            messages[index].content = blocks
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
