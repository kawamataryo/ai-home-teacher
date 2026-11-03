import Foundation

/// 割り込まれた返事の、実際に話したところまで（spec §3①「実際に再生した文字の位置で切り詰める」）。
struct SpokenSnapshot: Equatable, Sendable {
    /// 最後まで話した文（読み上げる前の、TeacherBrain が返した文のまま）
    var finished: [String]
    /// 話している途中だった文
    var current: String?
    /// `current` の何文字目まで話したか（Swift の Character 単位。TeacherVoice.stop() の戻り値）
    var playedInCurrent: Int
}

/// 履歴の切り詰め位置を決める（#13）。
///
/// 文の文字数を足すだけでは足りない。TeacherBrain の履歴には Claude の文字がそのまま入るが、
/// 文に区切るとき（SentenceSplitter）に文と文の間の改行や空白が落ちるので、そのぶん位置がずれる。
/// そこで、履歴の文字を先頭からたどり、話した文の文字と 1 つずつ突き合わせて位置を出す（空白は読み飛ばす）。
enum ReplyTruncation {
    /// 履歴の最後の先生の発言を何文字に切り詰めるか。切り詰めるものがなければ nil
    ///
    /// 最後のメッセージが先生の発言でないとき（まだ 1 文字も届いていない・ツールの結果が最後）は、
    /// 最後の先生の発言は前の返事なので切らない（0 に切ると前の返事を消してしまう）。
    static func targetCount(messages: [ChatMessage], spoken: SpokenSnapshot) -> Int? {
        guard let last = messages.last, last.role == .assistant else { return nil }
        let text = last.text
        let count = characterCount(in: text, spoken: spoken)
        return count < text.count ? count : nil
    }

    /// `text`（履歴の先生の発言）のうち、話したところまでの Character 数
    static func characterCount(in text: String, spoken: SpokenSnapshot) -> Int {
        let chars = Array(text)
        var cursor = 0
        for sentence in spoken.finished {
            // 見つからない文（ツールの呼び出しをはさんで前のメッセージにある文など）は飛ばす
            if let end = match(Array(sentence), in: chars, from: cursor) { cursor = end }
        }
        if let current = spoken.current, spoken.playedInCurrent > 0 {
            let played = Array(current.prefix(spoken.playedInCurrent))
            if let end = match(played, in: chars, from: cursor) { cursor = end }
        }
        return cursor
    }

    /// `from` 以降で `pattern` が（空白の違いを除いて）始まる最初の場所を探し、その終わりの位置を返す
    private static func match(_ pattern: [Character], in chars: [Character], from start: Int) -> Int? {
        guard !pattern.isEmpty else { return start }
        var origin = start
        while origin < chars.count {
            if let end = matchHere(pattern, in: chars, at: origin) { return end }
            origin += 1
        }
        return nil
    }

    private static func matchHere(_ pattern: [Character], in chars: [Character], at origin: Int) -> Int? {
        var i = origin
        for p in pattern {
            if !p.isWhitespace {
                // 文の区切りで落ちた改行・空白を読み飛ばす
                while i < chars.count, chars[i].isWhitespace { i += 1 }
            }
            guard i < chars.count, chars[i] == p else { return nil }
            i += 1
        }
        return i
    }
}

/// ConversationController と先生の声の間に入り、いまの返事で何を話したかを数える。
/// 割り込まれたら `snapshot(playedInCurrent:)` で話したところまでを取り、`invalidate()` で以降の記録を止める。
@MainActor
final class SpokenReplyTracker: SpeechOutput {
    private let voice: any TeacherSpeaking
    private var finished: [String] = []
    private var current: String?
    /// 返事ごと・止めるごとに増やす。止めたあとに戻ってきた speak を「最後まで話した」と数えない
    private var generation = 0

    init(voice: any TeacherSpeaking) {
        self.voice = voice
    }

    /// 新しい返事を数え始める
    func beginReply() {
        generation += 1
        finished = []
        current = nil
    }

    func speak(_ text: String) async {
        let id = generation
        current = text
        await voice.speak(text)
        guard id == generation else { return }
        finished.append(text)
        current = nil
    }

    func snapshot(playedInCurrent: Int) -> SpokenSnapshot {
        SpokenSnapshot(finished: finished, current: current, playedInCurrent: current == nil ? 0 : playedInCurrent)
    }

    /// 止めた。いま話している文が戻ってきても数えない
    func invalidate() {
        generation += 1
        current = nil
    }
}
