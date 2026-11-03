import Testing
@testable import HomeTeacher

struct EchoScoreTests {
    @Test func 再生文をそのまま認識したら混入率は1() {
        let s = "こんにちは、今日もがんばろう。"
        #expect(EchoScore.leakage(played: s, recognized: "こんにちは今日もがんばろう") == 1)
    }

    @Test func 何も認識しなければ混入率は0() {
        #expect(EchoScore.leakage(played: "こんにちは", recognized: "") == 0)
    }

    @Test func 子どもの声だけなら混入率は低い() {
        let leak = EchoScore.leakage(played: "まずは昨日の割合の問題から始めようか。", recognized: "待って")
        #expect(leak < 0.2)
    }

    @Test func 句読点と空白は無視する() {
        #expect(EchoScore.normalize("あ、 い。う！") == ["あ", "い", "う"])
    }
}
