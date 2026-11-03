import Foundation
import Testing
@testable import HomeTeacher

struct AnswerLeakGuardTests {
    private func blocks(_ answer: String, variants: [String] = [], _ sentence: String) -> Bool {
        AnswerLeakGuard(answer: answer, variants: variants).containsAnswer(sentence)
    }

    // MARK: 数

    @Test(arguments: [
        "答えは24cm²だよ。",
        "24平方センチメートルになるね。",
        "つまり、２４㎠。",
        "二十四平方センチだね",
        "答えは24！",
        "24.",
    ])
    func 面積の答えを止める(_ sentence: String) {
        #expect(blocks("24cm²", sentence))
    }

    @Test(arguments: [
        "たてが4cm、横が6cmだね。",
        "まず4×6をやってみよう。",
        "240cmじゃないよね？",
        "2.4ではないよ",
        "1つ分は何個かな？",
    ])
    func 答えでない数は止めない(_ sentence: String) {
        #expect(!blocks("24cm²", sentence))
    }

    @Test(arguments: ["24個あるね", "14はどう？", "0.4かな", "40にはならないよ", "4年生のときにやったね", "四角形の面積だよ"])
    func 数の境目と答えでない言い方は止めない(_ sentence: String) {
        #expect(!blocks("4", sentence))
    }

    @Test(arguments: ["答えは4だよ", "４になるね", "四つだね", "ということは、4！"])
    func 小さな数の答えを止める(_ sentence: String) {
        #expect(blocks("4", sentence))
    }

    @Test func 漢数字の言葉は数にしない() {
        #expect(!blocks("1", "一緒にやってみよう。"))
        #expect(!blocks("1", "一つずつ数えよう。"))
        #expect(!blocks("1", "一番大きいのはどれ？"))
        #expect(!blocks("3", "三角形の面積だね。"))
        #expect(!blocks("5", "五年生で習ったところだよ。"))
        #expect(!blocks("10", "十分考えたね。"))
        #expect(blocks("10", "答えは十だよ"))
    }

    @Test func 答えに単位があるとき別の単位の同じ数は止めない() {
        #expect(!blocks("4個", "12個を3人で分けるよ。4人だったらどうなる？"))
        #expect(blocks("4個", "1人4個だね。"))
        #expect(blocks("4個", "答えは4だよ。"))
    }

    @Test func 分数と小数と百分率() {
        #expect(blocks("3/4", "4分の3だね"))
        #expect(blocks("3/4", "四分の三になる"))
        #expect(blocks("3/4", "0.75だよ"))
        #expect(blocks("3/4", "３／４"))
        #expect(!blocks("3/4", "3分の4ではないよ"))
        #expect(!blocks("3/4", "3と4を比べよう"))
        #expect(blocks("2分の1", "1/2だよ"))

        #expect(blocks("75%", "75パーセントだね"))
        #expect(blocks("75%", "割合は0.75"))
        #expect(!blocks("75%", "7.5%かな？"))
        #expect(blocks("0.75", "75%になるね"))
    }

    @Test func 桁区切りと全角() {
        #expect(blocks("1200円", "1,200円になるよ"))
        #expect(blocks("1200円", "１２００円"))
        #expect(blocks("1200円", "千二百円"))
        #expect(!blocks("1200円", "120円が10個"))
        #expect(!blocks("1200", "1,200,000"))
    }

    @Test func 数が複数ある答えは全部出たら止める() {
        #expect(blocks("3時間20分", "3時間20分かかるね"))
        #expect(!blocks("3時間20分", "3時間でどこまで行ける？"))
    }

    @Test func 言いかえも照合する() {
        #expect(blocks("24cm²", variants: ["二十四平方センチメートル"], "にじゅうよん…じゃなくて、24だよ"))
        #expect(blocks("イ", variants: ["2番目の選択肢"], "2番目の選択肢だね"))
    }

    // MARK: 言葉と記号

    @Test func 言葉の答え() {
        #expect(blocks("東京", "答えは東京だよ"))
        #expect(blocks("三角形", "それは三角形だね"))
        #expect(blocks("Japan", "It is JAPAN."))
        #expect(!blocks("東京", "大阪と比べてみよう"))
    }

    @Test func 選択肢の記号は前後が同じ種類の文字なら止めない() {
        #expect(blocks("イ", "答えはイだよ"))
        #expect(blocks("イ", "「イ」が正解"))
        #expect(blocks("イ", "イ。"))
        #expect(blocks("ア", "ｱだね"))
        #expect(!blocks("イ", "イメージしてみよう"))
        #expect(!blocks("イ", "グラフのイチバン高いところ"))
        #expect(!blocks("ア", "アイスが好きな人は何人？"))
        #expect(blocks("B", "答えはBです"))
        #expect(!blocks("B", "Bonus"))
    }

    // MARK: 止めたときの動き

    @Test func 止めた文はかわりの文にする() {
        let guardian = AnswerLeakGuard(answer: "24cm²")
        #expect(guardian.check("答えは24cm²だよ。") == .blocked(replacement: AnswerLeakGuard.defaultReplacement))
        #expect(guardian.screen("答えは24cm²だよ。") == AnswerLeakGuard.defaultReplacement)
        #expect(guardian.screen("どこを見ればいいかな？") == "どこを見ればいいかな？")
    }

    @Test func 子どもが先に正答を言ったら先生は繰り返してよい() {
        var guardian = AnswerLeakGuard(answer: "24cm²")
        expectStep(guardian.noteChildUtterance("20かな？"), false)
        #expect(guardian.check("そう、24cm²だね！") != .allowed)
        expectStep(guardian.noteChildUtterance("にじゅうよん…24！"), true)
        #expect(guardian.isRevealedByChild)
        #expect(guardian.check("そう、24cm²だね！") == .allowed)
    }

    @Test func 作文や答えのないときは止めない() {
        let writing = ProblemAnalysis(kind: .writing, problemSummary: "", answer: "宝物", hintSteps: [])
        #expect(!AnswerLeakGuard(analysis: writing).isActive)
        #expect(AnswerLeakGuard(analysis: writing).check("宝物について書こう") == .allowed)
        #expect(AnswerLeakGuard(answer: "  ").check("なんでも") == .allowed)
    }

    @Test func 分析結果の正答と言いかえで作る() {
        let analysis = ProblemAnalysis(kind: .reading, problemSummary: "", answer: "3/4", answerVariants: ["75%"], hintSteps: [])
        let guardian = AnswerLeakGuard(analysis: analysis)
        #expect(guardian.check("4分の3だよ") != .allowed)
        #expect(guardian.check("75パーセントだね") != .allowed)
    }

    // MARK: 漢数字

    @Test func 漢数字を数に直す() {
        #expect(AnswerNormalizer.kanjiValue("二十四") == 24)
        #expect(AnswerNormalizer.kanjiValue("十") == 10)
        #expect(AnswerNormalizer.kanjiValue("三百五") == 305)
        #expect(AnswerNormalizer.kanjiValue("千二百") == 1200)
        #expect(AnswerNormalizer.kanjiValue("二〇二六") == 2026)
        #expect(AnswerNormalizer.kanjiValue("一万二千") == 12000)
    }
}
