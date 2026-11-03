import Foundation

/// 先生の返事に付く気持ちのしるし（`[praise]` / `[encourage]` / `[neutral]`、prompts/teacher.md）。
///
/// Haiku は返事の先頭にしるしを 1 つ付ける。しるしはアバターの表情（`AvatarEmotion`）にして、読み上げる前に取り除く。
/// 履歴（TeacherBrain）にはしるしを残したままにする（次の返事でもしるしを付け続けてもらうため）。
///
/// - 文のどこにあっても、知っているしるしは全部取り除く（読み上げで「praise」と言わないように）
/// - 全角のかっこ（［praise］）や大文字（[Praise]）も同じに読む
/// - 知らないしるし（[happy] など）はそのまま残す（ふつうの文のかっこを消さない）
enum EmotionTag {
    nonisolated(unsafe) private static let regex = try! NSRegularExpression(
        pattern: #"[\[［]\s*(praise|encourage|neutral)\s*[\]］]"#, options: [.caseInsensitive]
    )

    /// しるしを取り除いた文と、最初に見つかったしるしの表情（なければ nil）
    static func strip(_ sentence: String) -> (emotion: AvatarEmotion?, text: String) {
        let ns = sentence as NSString
        let matches = regex.matches(in: sentence, range: NSRange(location: 0, length: ns.length))
        guard let first = matches.first else { return (nil, sentence) }
        let emotion = AvatarEmotion(tag: ns.substring(with: first.range(at: 1)))
        let stripped = regex.stringByReplacingMatches(in: sentence, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        return (emotion, stripped.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 履歴からしるしを取り除く（ふり返り・問題の分析など、ほかのモデルに会話を渡すとき）。
    /// 空になった text は消し、中身のなくなったメッセージも消す（API は空の text を受け付けない）
    static func strip(_ messages: [ChatMessage]) -> [ChatMessage] {
        messages.compactMap { message in
            var copy = message
            copy.content = message.content.compactMap { block in
                guard case .text(let text) = block else { return block }
                let stripped = strip(text).text
                return stripped.isEmpty ? nil : .text(stripped)
            }
            return copy.content.isEmpty ? nil : copy
        }
    }
}
