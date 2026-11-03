import Foundation

/// 認識エンジンから届く書き起こし（確定 / 途中）を、いま聞いている発話 1 つ分の文字にまとめる。
///
/// `SpeechInput` は「発話全体の最新値」を送る約束なので、確定した区切りをためて、途中の文字を後ろにつなぐ。
/// 新しい発話が始まったら（`beginUtterance()`）、それまでの文字は前の発話のものとして数えない。
///
/// - SpeechTranscriber / DictationTranscriber：確定した区切りごとに結果が届く。途中の文字は今の区切りだけ
/// - SFSpeechRecognizer：認識を始めてからの全文が毎回届く（`cumulative: true`）
struct TranscriptAccumulator: Sendable {
    /// 途中の文字が、認識を始めてからの全文か
    let cumulative: Bool
    private var finalized = ""
    private var volatile = ""
    /// いまの発話が始まった位置（`full` の Character 数）
    private var base = 0
    /// いまの途中の文字（とそれを確定させる結果）は前の発話のもの（`discardCurrent()` のあと）
    private var skipsVolatileSegment = false

    init(cumulative: Bool = false) {
        self.cumulative = cumulative
    }

    private var full: String { finalized + volatile }

    /// まだ確定していない途中の文字があるか。確定の結果がこれを置きかえるだけなら、新しく話したことにはならない
    var hasVolatile: Bool { !volatile.isEmpty }

    /// いまの発話の文字
    var utterance: String {
        let text = skipsVolatileSegment ? finalized : full
        return String(text.dropFirst(min(base, text.count))).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 結果を 1 つ受け取る。発話の文字が変わったら true
    @discardableResult
    mutating func receive(_ text: String, isFinal: Bool) -> Bool {
        let before = utterance
        if isFinal {
            finalized += text
            volatile = ""
            if skipsVolatileSegment {
                // 捨てると決めた区切りが確定した。ここから先が新しい発話
                base = finalized.count
                skipsVolatileSegment = false
            }
        } else {
            volatile = text
        }
        return utterance != before
    }

    /// 新しい発話を始める。ここまでに確定した文字は前の発話のもの
    mutating func beginUtterance() {
        // 区切りごとに届くエンジンでは、途中の文字はもう新しい発話のもの。全文が届くエンジンでは全部が前の発話
        base = cumulative ? full.count : finalized.count
        skipsVolatileSegment = false
    }

    /// いま聞いている発話を、途中の文字も含めて捨てる（「勉強スタート」を聞き取った直後など）
    mutating func discardCurrent() {
        if cumulative {
            base = full.count
        } else {
            base = finalized.count
            skipsVolatileSegment = !volatile.isEmpty
        }
    }

    /// 全部捨てる（マイクを止めたときなど）
    mutating func reset() {
        finalized = ""
        volatile = ""
        base = 0
        skipsVolatileSegment = false
    }
}
