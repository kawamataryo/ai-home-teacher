import Foundation

/// ストリーミングで届く文字を、TTS に流す文の単位に区切る。
///
/// - 区切り: 。！？!? と改行。「！？」のような連続や、直後の閉じかっこ（」』）など）は前の文に含める
/// - 「」の中の 。！？ では区切らない（ただし長すぎるときは区切る）
/// - 末尾の区切り文字は、次の文字が来るまで（または `flush()` まで）確定しない
struct SentenceSplitter {
    static let terminators: Set<Character> = ["。", "！", "？", "!", "?"]
    static let openers: Set<Character> = ["「", "『", "（", "("]
    static let closers: Set<Character> = ["」", "』", "）", ")"]
    /// かっこの中でもこの文字数を超えたら区切る（TTS を待たせすぎない）。
    static let maxQuotedLength = 80

    private var buffer: [Character] = []

    /// 文字を足し、確定した文を返す。
    mutating func append(_ text: String) -> [String] {
        buffer.append(contentsOf: text)
        return drain(final: false)
    }

    /// 残りをすべて返す（ストリームの終わりで呼ぶ）。
    mutating func flush() -> [String] {
        drain(final: true)
    }

    private mutating func drain(final: Bool) -> [String] {
        var sentences: [String] = []
        while let end = nextBoundary(final: final) {
            let sentence = String(buffer[..<end.sentenceEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer.removeFirst(end.consumed)
            if !sentence.isEmpty { sentences.append(sentence) }
        }
        if final {
            let rest = String(buffer).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer.removeAll()
            if !rest.isEmpty { sentences.append(rest) }
        }
        return sentences
    }

    /// 次の文の終わり（文に含める位置）と、バッファから消す文字数。
    private func nextBoundary(final: Bool) -> (sentenceEnd: Int, consumed: Int)? {
        var depth = 0
        var i = 0
        while i < buffer.count {
            let c = buffer[i]
            if c == "\n" { return (i, i + 1) }
            if Self.openers.contains(c) {
                depth += 1
            } else if Self.closers.contains(c) {
                depth = max(0, depth - 1)
            } else if Self.terminators.contains(c), depth == 0 || i >= Self.maxQuotedLength {
                // 「！？」や「。」」のように続く記号を前の文に含める
                var j = i + 1
                while j < buffer.count, Self.terminators.contains(buffer[j]) || Self.closers.contains(buffer[j]) {
                    j += 1
                }
                // 末尾なら、次に「！」や「」」が来るかもしれないので待つ
                if j == buffer.count, !final { return nil }
                return (j, j)
            }
            i += 1
        }
        return nil
    }
}
