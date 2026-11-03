import Foundation

/// チャンクごとに届く文字タイミングを 1 文ぶんにつなげる
///
/// ElevenLabs の HTTP ストリームで、各チャンクの時刻が「文の先頭から」か「そのチャンクの先頭から」かは
/// 確かめられていない。時刻が前のチャンクの終わりより戻っていたら「チャンクの先頭から」とみなして、
/// 前のチャンクの終わりの時刻を足す。
struct TTSAlignmentMerger: Sendable {
    private(set) var merged: TTSAlignment?

    /// 前のチャンクより戻っているとみなす幅（秒）
    static let tolerance = 0.05

    init() {}

    mutating func append(_ alignment: TTSAlignment) {
        let count = min(
            alignment.characters.count,
            alignment.characterStartTimesSeconds.count,
            alignment.characterEndTimesSeconds.count
        )
        guard count > 0 else { return }
        var starts = Array(alignment.characterStartTimesSeconds.prefix(count))
        var ends = Array(alignment.characterEndTimesSeconds.prefix(count))
        guard var result = merged else {
            merged = TTSAlignment(characters: Array(alignment.characters.prefix(count)),
                                  characterStartTimesSeconds: starts, characterEndTimesSeconds: ends)
            return
        }
        let lastEnd = result.characterEndTimesSeconds.last ?? 0
        if starts[0] < lastEnd - Self.tolerance {
            starts = starts.map { $0 + lastEnd }
            ends = ends.map { $0 + lastEnd }
        }
        result.characters += alignment.characters.prefix(count)
        result.characterStartTimesSeconds += starts
        result.characterEndTimesSeconds += ends
        merged = result
    }
}

/// 再生した位置から「何文字目まで話したか」を出す（割り込み時に、先生の発言を話したところで切るのに使う #13）
enum PlaybackProgress {
    /// `time` 秒までに読み始めた文字の数（Swift の `Character` 単位、0...text.count）
    ///
    /// - 文字タイミングがあれば、開始時刻が `time` 以下の文字を「話した」とする（言いかけた文字も含める）。
    ///   タイミングの文字をつなげたものが `text` と一致すれば、Unicode スカラーの数で `text` に当てはめる
    ///   （絵文字など、1 文字が複数のスカラーでできていても数え間違えない）。一致しなければ割合で見積もる。
    /// - 文字タイミングがなければ、再生時間の割合で見積もる。
    static func playedCharacterCount(
        of text: String,
        alignment: TTSAlignment?,
        at time: TimeInterval,
        duration: TimeInterval? = nil
    ) -> Int {
        let total = text.count
        guard total > 0, time >= 0 else { return 0 }

        guard let alignment, !alignment.characters.isEmpty else {
            guard let duration, duration > 0 else { return 0 }
            return clamp(Int((Double(total) * time / duration).rounded(.down)), total)
        }

        let count = min(alignment.characters.count, alignment.characterStartTimesSeconds.count)
        let started = alignment.characterStartTimesSeconds.prefix(count).prefix { $0 <= time }.count
        guard started > 0 else { return 0 }
        if started >= count, let end = alignment.characterEndTimesSeconds.last, time >= end { return total }

        let characters = alignment.characters.prefix(count)
        guard characters.joined() == text else {
            return clamp(Int((Double(total) * Double(started) / Double(count)).rounded(.down)), total)
        }
        let playedScalars = characters.prefix(started).reduce(0) { $0 + $1.unicodeScalars.count }
        // 先頭のスカラーまで読んだ Character を数える
        var scalarOffset = 0
        var played = 0
        for character in text {
            guard scalarOffset < playedScalars else { break }
            played += 1
            scalarOffset += character.unicodeScalars.count
        }
        return clamp(played, total)
    }

    private static func clamp(_ value: Int, _ total: Int) -> Int {
        min(max(value, 0), total)
    }
}
