import Foundation
import Testing
@testable import HomeTeacher

struct EmotionTagTests {
    @Test(arguments: [
        ("[praise]そう、よく気づいたね！", AvatarEmotion.praise, "そう、よく気づいたね！"),
        ("[encourage]おしい！", .encourage, "おしい！"),
        ("[neutral]どれどれ？", .neutral, "どれどれ？"),
        // 全角のかっこ・大文字・前後の空白
        ("［Praise］ いいね！", .praise, "いいね！"),
        ("  [ ENCOURAGE ]だいじょうぶ。", .encourage, "だいじょうぶ。"),
    ])
    func 先頭のしるしを表情にして取り除く(input: String, emotion: AvatarEmotion, text: String) {
        let result = EmotionTag.strip(input)
        #expect(result.emotion == emotion)
        #expect(result.text == text)
    }

    @Test func しるしがなければそのまま() {
        let result = EmotionTag.strip("4×6を計算してみよう。")
        #expect(result.emotion == nil)
        #expect(result.text == "4×6を計算してみよう。")
    }

    @Test func 文の途中のしるしも読み上げない() {
        let result = EmotionTag.strip("いいね！[praise]どうしてそう思った？")
        #expect(result.emotion == .praise)
        #expect(result.text == "いいね！どうしてそう思った？")
    }

    @Test func 知らないしるしやふつうのかっこは消さない() {
        #expect(EmotionTag.strip("[happy]やったね").text == "[happy]やったね")
        #expect(EmotionTag.strip("[ア]と[イ]のどっち？").text == "[ア]と[イ]のどっち？")
    }

    @Test func しるしだけの文は空になる() {
        // 「[praise]\nそう！」は SentenceSplitter が改行で区切るので、しるしだけの文が届く
        var splitter = SentenceSplitter()
        let sentences = splitter.append("[praise]\nそう！") + splitter.flush()
        #expect(sentences.map { EmotionTag.strip($0).text }.filter { !$0.isEmpty } == ["そう！"])
        #expect(EmotionTag.strip(sentences[0]).emotion == .praise)
    }

    @Test func しるしの残った履歴でも話したところまでで切り詰められる() {
        // 履歴にはしるしが残り、読み上げた文にはない。突き合わせはしるしを読み飛ばす
        let history = "[praise]そう！どうしてそう思った？"
        let spoken = SpokenSnapshot(finished: ["そう！"], current: "どうしてそう思った？", playedInCurrent: 4)
        let count = ReplyTruncation.characterCount(in: history, spoken: spoken)
        #expect(String(history.prefix(count)) == "[praise]そう！どうして")
    }
}
