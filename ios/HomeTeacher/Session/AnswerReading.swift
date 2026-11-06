import Foundation

/// 発話と正答を読み（ローマ字）で比べる（#135）。
///
/// 音声認識は同じ読みの別の漢字に変換することがある（「工場」→「向上」）。文字だけで比べると、
/// 正しく答えたのに違うと判定してしまう。読みの比較は端末の中で決まり、通信もしない。
///
/// - 数を含む答えは比べない（数は AnswerLeakGuard の表記揃えと Jev に任せる）
/// - 読みが短い答えは比べない（「市（shi）」が「しかく」に一致してしまう）
enum AnswerReading {
    static let minimumLength = 5

    /// 発話のどこかに、答えのどれかと同じ読みがあるか。
    /// 単語の境目をそろえて比べる（「今日とても」の kyou + totemo が「京都（kyouto）」に一致しないように）
    static func containsSameReading(_ utterance: String, answers: [String]) -> Bool {
        // 数の答えだけの問題では読みを取らない（ふつうの算数の問題に手間をかけない）
        let candidates = answers.filter { !$0.contains(where: \.isNumber) }
        guard !candidates.isEmpty else { return false }
        let spoken = words(utterance)
        return candidates.contains { answer in
            let target = words(answer).joined()
            guard target.count >= minimumLength, target.allSatisfy(\.isLetter) else { return false }
            return spoken.indices.contains { start in
                var joined = ""
                for word in spoken[start...] where joined.count < target.count {
                    joined += word
                }
                return joined == target
            }
        }
    }

    /// 単語ごとの読み。空白・句読点・記号は入らない
    static func words(_ text: String) -> [String] {
        let source = text as CFString
        let tokenizer = CFStringTokenizerCreate(
            nil, source, CFRange(location: 0, length: CFStringGetLength(source)),
            kCFStringTokenizerUnitWord, Locale(identifier: "ja_JP") as CFLocale
        )
        var result: [String] = []
        while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
            if let latin = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String {
                result.append(latin.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil))
            }
        }
        return result
    }
}
