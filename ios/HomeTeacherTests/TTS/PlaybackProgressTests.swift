import Foundation
import Testing
@testable import HomeTeacher

struct TTSAlignmentMergerTests {
    @Test func 文の先頭からの時刻はそのままつなぐ() {
        var merger = TTSAlignmentMerger()
        merger.append(evenAlignment("あい"))
        merger.append(evenAlignment("うえ", offset: 0.2))
        #expect(merger.merged == evenAlignment("あいうえ"))
    }

    @Test func チャンクの先頭からの時刻は前の終わりを足す() {
        var merger = TTSAlignmentMerger()
        merger.append(evenAlignment("あい"))
        merger.append(evenAlignment("うえ"))
        let starts = merger.merged?.characterStartTimesSeconds.map { ($0 * 10).rounded() / 10 }
        #expect(starts == [0, 0.1, 0.2, 0.3])
    }
}

struct PlaybackProgressTests {
    @Test func 読み始めた文字まで数える() {
        let text = "いいね！"
        let alignment = evenAlignment(text)
        #expect(PlaybackProgress.playedCharacterCount(of: text, alignment: alignment, at: 0) == 1)
        #expect(PlaybackProgress.playedCharacterCount(of: text, alignment: alignment, at: 0.15) == 2)
        #expect(PlaybackProgress.playedCharacterCount(of: text, alignment: alignment, at: 0.39) == 4)
        #expect(PlaybackProgress.playedCharacterCount(of: text, alignment: alignment, at: 5) == 4)
    }

    @Test func 始まる前は0() {
        let alignment = evenAlignment("あいう", offset: 0.2)
        #expect(PlaybackProgress.playedCharacterCount(of: "あいう", alignment: alignment, at: 0.1) == 0)
        #expect(PlaybackProgress.playedCharacterCount(of: "", alignment: nil, at: 1) == 0)
    }

    @Test func 複数のスカラーでできた文字もCharacterで数える() {
        // 👍🏽 は 2 スカラー、か゚ は 2 スカラー（タイミングはスカラーごとに来ることがある）
        let text = "👍🏽か゚あ"
        let alignment = TTSAlignment(
            characters: ["👍", "🏽", "か", "\u{309A}", "あ"],
            characterStartTimesSeconds: [0, 0.1, 0.2, 0.3, 0.4],
            characterEndTimesSeconds: [0.1, 0.2, 0.3, 0.4, 0.5]
        )
        #expect(text.count == 3)
        #expect(PlaybackProgress.playedCharacterCount(of: text, alignment: alignment, at: 0.05) == 1)
        #expect(PlaybackProgress.playedCharacterCount(of: text, alignment: alignment, at: 0.15) == 1)
        #expect(PlaybackProgress.playedCharacterCount(of: text, alignment: alignment, at: 0.25) == 2)
        #expect(PlaybackProgress.playedCharacterCount(of: text, alignment: alignment, at: 0.45) == 3)
    }

    @Test func タイミングの文字が文と違えば割合で見積もる() {
        // 正規化されて文字数が変わったとき（"5" → "ご"）
        let alignment = evenAlignment("あとごふん")
        let count = PlaybackProgress.playedCharacterCount(of: "あと5分", alignment: alignment, at: 0.25)
        #expect(count == 2)
        #expect(PlaybackProgress.playedCharacterCount(of: "あと5分", alignment: alignment, at: 1) == 4)
    }

    @Test func タイミングがなければ再生時間の割合で見積もる() {
        #expect(PlaybackProgress.playedCharacterCount(of: "あいうえ", alignment: nil, at: 0.5, duration: 1) == 2)
        #expect(PlaybackProgress.playedCharacterCount(of: "あいうえ", alignment: nil, at: 2, duration: 1) == 4)
        #expect(PlaybackProgress.playedCharacterCount(of: "あいうえ", alignment: nil, at: 0.5) == 0)
    }
}
