import Foundation
import Testing
@testable import HomeTeacher

struct VoiceActivityDetectorTests {
    private let t0 = ContinuousClock.now
    private func at(_ ms: Int) -> ContinuousClock.Instant { t0 + .milliseconds(ms) }

    @Test func 開くしきい値を続けて超えたら話し始め() {
        var vad = VoiceActivityDetector(startThreshold: 0.02, endThreshold: 0.01, attack: .milliseconds(100), release: .milliseconds(300))
        #expect(vad.process(level: 0.05, at: at(0)) == nil)
        #expect(vad.process(level: 0.05, at: at(50)) == nil)
        #expect(vad.process(level: 0.05, at: at(100)) == .started)
        #expect(vad.isActive)
    }

    @Test func 短い物音では話し始めにしない() {
        var vad = VoiceActivityDetector(attack: .milliseconds(100))
        #expect(vad.process(level: 0.05, at: at(0)) == nil)
        #expect(vad.process(level: 0.001, at: at(50)) == nil)
        #expect(vad.process(level: 0.05, at: at(120)) == nil)
        #expect(!vad.isActive)
    }

    @Test func 閉じるしきい値の間は話し終わりにしない() {
        var vad = VoiceActivityDetector(startThreshold: 0.02, endThreshold: 0.01, attack: .zero, release: .milliseconds(300))
        #expect(vad.process(level: 0.05, at: at(0)) == .started)
        // 開くしきい値より小さいが、閉じるしきい値より大きい（ヒステリシス）
        #expect(vad.process(level: 0.015, at: at(400)) == nil)
        #expect(vad.process(level: 0.001, at: at(500)) == nil)
        #expect(vad.process(level: 0.001, at: at(800)) == .ended)
        #expect(!vad.isActive)
    }

    @Test func 文字が届いたら話し始めにし少しの間は閉じない() {
        var vad = VoiceActivityDetector(release: .milliseconds(300), textHold: .milliseconds(600))
        #expect(vad.noteText(at: at(0)) == .started)
        #expect(vad.process(level: 0, at: at(400)) == nil)
        #expect(vad.process(level: 0, at: at(650)) == .ended)
    }
}

struct TranscriptAccumulatorTests {
    @Test func 確定した区切りをためて途中の文字をつなぐ() {
        var t = TranscriptAccumulator()
        t.receive("ねえ先生", isFinal: false)
        #expect(t.utterance == "ねえ先生")
        t.receive("ねえ先生、", isFinal: true)
        t.receive("これ", isFinal: false)
        #expect(t.utterance == "ねえ先生、これ")
    }

    @Test func 新しい発話は前の発話の文字を数えない() {
        var t = TranscriptAccumulator()
        t.receive("終わりの問題", isFinal: true)
        t.beginUtterance()
        #expect(t.utterance == "")
        t.receive("つぎ", isFinal: false)
        #expect(t.utterance == "つぎ")
    }

    @Test func コマンドを捨てると遅れて届く確定も数えない() {
        var t = TranscriptAccumulator()
        t.receive("勉強スタート", isFinal: false)
        t.discardCurrent()
        #expect(t.utterance == "")
        t.receive("勉強スタート。", isFinal: true)
        #expect(t.utterance == "")
        t.receive("ねえ先生", isFinal: false)
        #expect(t.utterance == "ねえ先生")
    }

    @Test func 全文が届くエンジンでは始めた位置から数える() {
        var t = TranscriptAccumulator(cumulative: true)
        t.receive("こんにちは", isFinal: false)
        t.beginUtterance()
        t.receive("こんにちはねえ先生", isFinal: false)
        #expect(t.utterance == "ねえ先生")
    }
}

struct SpeechEventShaperTests {
    private let t0 = ContinuousClock.now
    private func at(_ ms: Int) -> ContinuousClock.Instant { t0 + .milliseconds(ms) }

    private func shaper() -> SpeechEventShaper {
        SpeechEventShaper(
            detector: VoiceActivityDetector(attack: .zero, release: .milliseconds(300), textHold: .milliseconds(300)),
            utteranceGap: .milliseconds(900)
        )
    }

    @Test func 声と文字から出来事を作る() {
        var s = shaper()
        #expect(s.level(0.05, at: at(0)) == [.voiceStarted])
        #expect(s.text("ねえ", isFinal: false, at: at(100)) == [.transcript("ねえ")])
        #expect(s.text("ねえ先生", isFinal: false, at: at(200)) == [.transcript("ねえ先生")])
        #expect(s.level(0, at: at(300)) == [])
        #expect(s.level(0, at: at(600)) == [.voiceEnded])
    }

    @Test func 区切ったあとに遅れて届く確定は話し始めにしない() {
        var s = shaper()
        _ = s.level(0.05, at: at(0))
        _ = s.text("これ見て", isFinal: false, at: at(100))
        #expect(s.level(0, at: at(500)) == [.voiceEnded])
        // 1.5 秒後に確定が届く。話し始めは出さない（同じ発話が 2 回受け付けられないように）
        #expect(s.text("これ見て。", isFinal: true, at: at(2000)) == [.transcript("これ見て。")])
        // 次に話し始めたら、前の文字は数えない
        #expect(s.level(0.05, at: at(3000)) == [.voiceStarted])
        #expect(s.text("つぎ", isFinal: false, at: at(3100)) == [.transcript("つぎ")])
    }

    @Test func 息継ぎは同じ発話の続きとして文字をつなぐ() {
        var s = shaper()
        _ = s.level(0.05, at: at(0))
        _ = s.text("ねえ先生、", isFinal: true, at: at(100))
        #expect(s.level(0, at: at(500)) == [.voiceEnded])
        #expect(s.level(0.05, at: at(800)) == [.voiceStarted, .transcript("ねえ先生、")])
        #expect(s.text("これ", isFinal: false, at: at(900)) == [.transcript("ねえ先生、これ")])
    }

    @Test func ミュート中は何も出さない() {
        var s = shaper()
        s.setMuted(true)
        #expect(s.level(0.5, at: at(0)) == [])
        #expect(s.text("先生の声", isFinal: false, at: at(10)) == [])
        s.setMuted(false)
        #expect(s.level(0.05, at: at(100)) == [.voiceStarted])
    }
}

struct VoiceCommandTests {
    @Test(arguments: ["勉強スタート", "勉強スタート！", "ねえ先生、勉強スタート", "べんきょうスタート", "よし、勉強始めよう"])
    func 始める(_ text: String) {
        #expect(VoiceCommand.parse(text) == .start)
    }

    @Test(arguments: ["終わり", "終わり！", "おわり", "今日は終わり", "勉強終わり", "先生、終わりにする", "もう終わりにしよう", "おしまい"])
    func 終わる(_ text: String) {
        #expect(VoiceCommand.parse(text) == .end)
    }

    @Test(arguments: ["終わりの問題がわからない", "これで終わりかな、答えは24？", "ねえ先生、これ見て", "スタートってどういう意味"])
    func コマンドではない(_ text: String) {
        #expect(VoiceCommand.parse(text) == nil)
    }
}
