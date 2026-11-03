import Testing
@testable import HomeTeacher

struct SentenceSplitterTests {
    /// まとめて渡して最後に flush した結果。
    private func split(_ text: String) -> [String] {
        var splitter = SentenceSplitter()
        return splitter.append(text) + splitter.flush()
    }

    /// 1文字ずつ渡して最後に flush した結果。
    private func splitByCharacter(_ text: String) -> [String] {
        var splitter = SentenceSplitter()
        var out: [String] = []
        for c in text { out += splitter.append(String(c)) }
        return out + splitter.flush()
    }

    @Test(arguments: [
        ("お、いいね！それで？", ["お、いいね！", "それで？"]),
        ("どこを見ればいいかな。表の2行目だよ。", ["どこを見ればいいかな。", "表の2行目だよ。"]),
        ("ほんと！？すごいじゃん。", ["ほんと！？", "すごいじゃん。"]),
        ("Why?Because!", ["Why?", "Because!"]),
        ("1行目\n2行目", ["1行目", "2行目"]),
        ("\n\n  空白だけの行は消す。\n", ["空白だけの行は消す。"]),
        ("3.5は小数だね。", ["3.5は小数だね。"]),
        ("終わりがない", ["終わりがない"]),
        ("", []),
    ])
    func 区切り文字と改行で分ける(input: String, expected: [String]) {
        #expect(split(input) == expected)
    }

    @Test func かっこの中では区切らない() {
        #expect(split("先生は「いいね。がんばろう！」って言ったよ。次ね。")
            == ["先生は「いいね。がんばろう！」って言ったよ。", "次ね。"])
    }

    @Test func 区切りの直後の閉じかっこは前の文に入れる() {
        #expect(split("「できた！」すごい。") == ["「できた！」すごい。"])
        #expect(split("（ここ大事。）では次。") == ["（ここ大事。）では次。"])
        #expect(split("まず「なに？」。それから。") == ["まず「なに？」。", "それから。"])
    }

    @Test func 閉じないかっこも最後に流す() {
        #expect(split("「まだ続く") == ["「まだ続く"])
    }

    @Test func かっこが長すぎるときは中でも区切る() {
        let long = String(repeating: "あ", count: SentenceSplitter.maxQuotedLength)
        let result = split("「\(long)。続き。」")
        #expect(result.count == 2)
        #expect(result[0] == "「\(long)。")
    }

    @Test(arguments: [
        "お、いいね！それで？",
        "ほんと！？すごいじゃん。",
        "先生は「いいね。がんばろう！」って言ったよ。次ね。",
        "1行目\n2行目。3つ目",
        "まず「なに？」。それから。",
    ])
    func 一文字ずつ届いても結果は同じ(input: String) {
        #expect(splitByCharacter(input) == split(input))
    }

    @Test func 末尾の区切りは次の文字が来るまで待つ() {
        var splitter = SentenceSplitter()
        #expect(splitter.append("すごい！") == [])
        #expect(splitter.append("！次。") == ["すごい！！"])
        #expect(splitter.flush() == ["次。"])
    }
}
