import Foundation

/// 学習セッションを声で始める・終えるコマンド（spec §3①「勉強スタート」で開始、「終わり」で終了）。
enum VoiceCommand: Equatable, Sendable {
    case start
    case end

    static let startPhrases = [
        "勉強スタート", "べんきょうスタート", "勉強すたーと", "べんきょうすたーと",
        "勉強始め", "勉強はじめ", "べんきょうはじめ", "勉強を始め", "勉強をはじめ",
    ]
    /// 終わりの言い方。「終わりの問題がわからない」のような文で終わらないよう、発話がこれで終わる短い文だけを見る
    static let endPhrases = [
        "終わり", "おわり", "終わりにする", "おわりにする", "終わりにしよう", "おわりにしよう",
        "終わります", "おわります", "おしまい", "終了",
    ]
    /// 「終わり」の前に付いてよい言葉（「今日は終わり」「勉強終わり」）
    static let endPrefixes = ["", "今日は", "きょうは", "今日はもう", "もう", "勉強", "べんきょう", "勉強は", "じゃあ", "じゃあ今日は", "それじゃあ"]

    /// 書き起こしからコマンドを読む。コマンドでなければ nil
    static func parse(_ utterance: String) -> VoiceCommand? {
        var text = normalize(utterance)
        // 「ねえ先生、終わり」のような呼びかけは外して考える
        for word in ConversationSettings.defaultCallWords.map(normalize).sorted(by: { $0.count > $1.count }) where text.hasPrefix(word) {
            text.removeFirst(word.count)
            break
        }
        if startPhrases.contains(where: { text.contains(normalize($0)) }) { return .start }
        // 語尾のゆれ（「終わり！」「終わりね」「終わりー」）は少しだけ許す
        for suffix in ["ね", "よ", "ー", "〜", "で", "でいい", "にして", ""] {
            guard suffix.isEmpty || text.hasSuffix(suffix) else { continue }
            let body = String(text.dropLast(suffix.count))
            for phrase in endPhrases {
                if endPrefixes.contains(where: { body == normalize($0 + phrase) }) { return .end }
            }
        }
        return nil
    }

    private static func normalize(_ s: String) -> String {
        String(s.precomposedStringWithCompatibilityMapping.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.punctuationCharacters.contains($0)
                && !CharacterSet.symbols.contains($0)
        })
    }
}
