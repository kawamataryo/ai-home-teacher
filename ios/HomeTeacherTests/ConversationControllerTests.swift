import Foundation
import Testing
@testable import HomeTeacher

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ConversationControllerTests {
    // MARK: - 状態の遷移

    @Test func 待機から聞き取り中_考え中_発話中を経て待機に戻る() async {
        let h = ConversationHarness()
        #expect(h.controller.state == .idle)

        h.controller.handle(.voiceStarted)
        #expect(h.controller.state == .listening)
        h.controller.handle(.transcript("ねえ先生、これ教えて"))
        h.controller.handle(.voiceEnded)
        #expect(h.controller.state == .listening)

        h.clock.advance(by: .milliseconds(700))
        #expect(await h.nextEvent() == .userTurnAccepted("ねえ先生、これ教えて"))
        #expect(h.controller.state == .thinking)

        h.output.holdsPlayback = true
        let speaking = Task { await h.controller.speak("いいよ、見せて") }
        await h.output.waitUntilSpeaking()
        #expect(h.controller.state == .speaking)

        h.output.finishCurrent()
        #expect(await speaking.value == .completed)
        #expect(h.controller.state == .idle)
        #expect(h.output.spoken == ["いいよ、見せて"])
    }

    @Test func 物音だけで言葉がなければ待機に戻る() {
        let h = ConversationHarness()
        h.controller.handle(.voiceStarted)
        h.controller.handle(.voiceEnded)
        h.clock.advance(by: .milliseconds(700))
        #expect(h.controller.state == .idle)
    }

    @Test func 聞き取り中と発話中は話さない() async {
        let h = ConversationHarness()
        h.controller.handle(.voiceStarted)
        #expect(await h.controller.speak("こんにちは") == .rejected)
        #expect(h.output.spoken.isEmpty)
        #expect(h.controller.state == .listening)
    }

    @Test func 待機中なら先生から声をかけられる() async {
        let h = ConversationHarness()
        #expect(await h.controller.speak("そろそろ休憩しよっか") == .completed)
        #expect(h.output.spoken == ["そろそろ休憩しよっか"])
        #expect(h.controller.state == .idle)
    }

    @Test func 複数の文を順に話す() async {
        let h = ConversationHarness()
        let sentences = AsyncStream<String> {
            $0.yield("いいね！")
            $0.yield("次はここを見てみよう。")
            $0.finish()
        }
        #expect(await h.controller.speak(sentences) == .completed)
        #expect(h.output.spoken == ["いいね！", "次はここを見てみよう。"])
    }

    @Test func 応答を取りやめると待機に戻る() async {
        let h = ConversationHarness()
        #expect(await h.sayAndFinish("先生、これわかんない") == .userTurnAccepted("先生、これわかんない"))
        h.controller.cancelResponse()
        #expect(h.controller.state == .idle)
    }

    @Test func start後は音声入力のストリームから出来事を受け取る() async {
        let decider = StubEndOfUtteranceDecider { _ in true }
        let h = ConversationHarness(endOfUtteranceDecider: decider)
        h.controller.start()
        h.input.continuation.yield(.voiceStarted)
        h.input.continuation.yield(.transcript("ねえ先生"))
        h.input.continuation.yield(.voiceEnded)
        #expect(await h.nextEvent() == .userTurnAccepted("ねえ先生"))
        h.controller.stop()
        #expect(h.controller.state == .idle)
    }

    // MARK: - 呼びかけ語

    @Test func 呼びかけ語がなく先生も話していなければ無視する() async {
        let h = ConversationHarness()
        #expect(await h.sayAndFinish("これむずいなー") == .utteranceIgnored("これむずいなー"))
        #expect(h.controller.state == .idle)
    }

    @Test func 呼びかけ語は設定で変えられる() async {
        let h = ConversationHarness(settings: ConversationSettings(callWords: ["ティーチャー"]))
        #expect(await h.sayAndFinish("ティーチャー、聞いて") == .userTurnAccepted("ティーチャー、聞いて"))
        h.controller.cancelResponse()
        #expect(await h.sayAndFinish("先生、聞いて") == .utteranceIgnored("先生、聞いて"))
    }

    @Test func 差し替えた判定が先生への発話と判断すれば呼びかけ語がなくても応答する() async {
        let judge = StubAddressingJudge(true)
        let h = ConversationHarness(addressingJudge: judge)
        #expect(await h.sayAndFinish("これどうやるの") == .userTurnAccepted("これどうやるの"))
        #expect(judge.asked == ["これどうやるの"])
    }

    @Test func 差し替えた判定が違うと判断すれば呼びかけ語があっても無視する() async {
        let h = ConversationHarness(addressingJudge: StubAddressingJudge(false))
        #expect(await h.sayAndFinish("先生ってさ") == .utteranceIgnored("先生ってさ"))
    }

    // MARK: - 30 秒ルール

    @Test func 先生の発話から30秒以内なら呼びかけ語なしでも応答する() async {
        let judge = StubAddressingJudge(false)
        let h = ConversationHarness(addressingJudge: judge)
        await h.controller.speak("この問題、どう思う？")
        h.clock.advance(by: .seconds(30))
        #expect(await h.sayAndFinish("たぶん3かな") == .userTurnAccepted("たぶん3かな"))
        // 30 秒以内の続きは判定を呼ばない
        #expect(judge.asked.isEmpty)
    }

    @Test func 先生の発話から30秒を過ぎたら呼びかけ語が必要() async {
        let h = ConversationHarness()
        await h.controller.speak("この問題、どう思う？")
        h.clock.advance(by: .seconds(30) + .milliseconds(1))
        #expect(await h.sayAndFinish("たぶん3かな") == .utteranceIgnored("たぶん3かな"))
    }

    @Test func 続きの30秒は話し始めた時刻で数える() async {
        let h = ConversationHarness()
        await h.controller.speak("どう思う？")
        h.clock.advance(by: .seconds(29))
        h.controller.handle(.voiceStarted)
        h.controller.handle(.transcript("えっとね、たぶん"))
        h.clock.advance(by: .seconds(5))
        h.controller.handle(.voiceEnded)
        h.clock.advance(by: .milliseconds(700))
        #expect(await h.nextEvent() == .userTurnAccepted("えっとね、たぶん"))
    }

    @Test func 続きの30秒は応答のたびに先生の発話の終わりから数え直す() async {
        let h = ConversationHarness()
        await h.controller.speak("どう思う？")
        h.clock.advance(by: .seconds(20))
        #expect(await h.sayAndFinish("3かな") == .userTurnAccepted("3かな"))
        h.clock.advance(by: .seconds(5))
        await h.controller.speak("どうして？")
        h.clock.advance(by: .seconds(25))
        #expect(await h.sayAndFinish("かけ算したから") == .userTurnAccepted("かけ算したから"))
    }

    @Test func 割り込みで止めた時刻からも30秒を数える() async {
        let h = ConversationHarness()
        h.output.holdsPlayback = true
        let speaking = Task { await h.controller.speak("じゃあ次の問題は…") }
        await h.output.waitUntilSpeaking()
        h.clock.advance(by: .seconds(10))
        h.controller.handle(.voiceStarted)
        #expect(await h.nextEvent() == .bargeIn(during: .speaking))
        h.output.finishCurrent()
        _ = await speaking.value
        // 割り込んだ発話は物音だった
        h.controller.handle(.voiceEnded)
        h.clock.advance(by: .milliseconds(700))
        #expect(h.controller.state == .idle)

        h.clock.advance(by: .seconds(29))
        #expect(await h.sayAndFinish("やっぱりいいや") == .userTurnAccepted("やっぱりいいや"))
    }

    // MARK: - 終話判定

    @Test func 無音が700ms続いたら言い終わったとみなす() async {
        let h = ConversationHarness()
        h.say("ねえ先生")
        h.clock.advance(by: .milliseconds(699))
        #expect(h.controller.state == .listening)
        h.clock.advance(by: .milliseconds(1))
        #expect(await h.nextEvent() == .userTurnAccepted("ねえ先生"))
    }

    @Test func 息継ぎで声が戻ったら最後に止まってから700ms待つ() async {
        let h = ConversationHarness()
        h.controller.handle(.voiceStarted)
        h.controller.handle(.transcript("ねえ先生"))
        h.controller.handle(.voiceEnded)
        h.clock.advance(by: .milliseconds(500))
        h.controller.handle(.voiceStarted)
        h.clock.advance(by: .milliseconds(500))
        #expect(h.controller.state == .listening)
        h.controller.handle(.transcript("ねえ先生、ここってさ"))
        h.controller.handle(.voiceEnded)
        h.clock.advance(by: .milliseconds(699))
        #expect(h.controller.state == .listening)
        h.clock.advance(by: .milliseconds(1))
        #expect(await h.nextEvent() == .userTurnAccepted("ねえ先生、ここってさ"))
    }

    @Test func 無音の長さは設定で変えられる() async {
        let h = ConversationHarness(settings: ConversationSettings(endOfUtteranceSilence: .seconds(1)))
        h.say("先生")
        h.clock.advance(by: .milliseconds(999))
        #expect(h.controller.state == .listening)
        h.clock.advance(by: .milliseconds(1))
        #expect(await h.nextEvent() == .userTurnAccepted("先生"))
    }

    @Test func 言い終わった判定がtrueなら700msを待たずに区切る() async {
        let decider = StubEndOfUtteranceDecider { _ in true }
        let h = ConversationHarness(endOfUtteranceDecider: decider)
        h.say("先生、できた")
        #expect(await h.nextEvent() == .userTurnAccepted("先生、できた"))
        #expect(decider.asked == ["先生、できた"])
    }

    @Test func 言い終わった判定がfalseなら700msを待つ() async {
        let decider = StubEndOfUtteranceDecider { _ in false }
        let h = ConversationHarness(endOfUtteranceDecider: decider)
        h.say("先生、あのね")
        await decider.waitUntilAsked()
        #expect(h.controller.state == .listening)
        h.clock.advance(by: .milliseconds(700))
        #expect(await h.nextEvent() == .userTurnAccepted("先生、あのね"))
    }

    @Test func 言い終わった判定の返事より前に話し始めていたら区切らない() async {
        let decider = StubEndOfUtteranceDecider { _ in false }
        let h = ConversationHarness(endOfUtteranceDecider: decider)
        decider.onCall = { [h] _ in
            // 判定の返事が来る前に子どもが続きを話し始めた
            h.controller.handle(.voiceStarted)
            return true
        }
        h.say("先生、あのね")
        await decider.waitUntilAsked()
        #expect(h.controller.state == .listening)

        decider.onCall = { _ in false }
        h.controller.handle(.transcript("先生、あのね、ここなんだけど"))
        h.controller.handle(.voiceEnded)
        h.clock.advance(by: .milliseconds(700))
        #expect(await h.nextEvent() == .userTurnAccepted("先生、あのね、ここなんだけど"))
    }

    // MARK: - 割り込み（barge-in）

    @Test func 発話中に話し始めたら割り込みを通知して聞き取りに移る() async {
        let h = ConversationHarness()
        h.output.holdsPlayback = true
        let sentences = AsyncStream<String> {
            $0.yield("この問題はね、")
            $0.yield("まず式を見てみよう。")
            $0.finish()
        }
        let speaking = Task { await h.controller.speak(sentences) }
        await h.output.waitUntilSpeaking()

        h.controller.handle(.voiceStarted)
        #expect(await h.nextEvent() == .bargeIn(during: .speaking))
        #expect(h.controller.state == .listening)

        // 再生が後から終わっても、聞き取り中のまま。残りの文は話さない
        h.output.finishCurrent()
        #expect(await speaking.value == .interrupted)
        #expect(h.controller.state == .listening)
        #expect(h.output.spoken == ["この問題はね、"])
        #expect(h.input.mutedHistory.isEmpty)

        // 割り込んだ発話は呼びかけ語がなくても応答する
        h.controller.handle(.transcript("わかった、自分でやる"))
        h.controller.handle(.voiceEnded)
        h.clock.advance(by: .milliseconds(700))
        #expect(await h.nextEvent() == .userTurnAccepted("わかった、自分でやる"))
    }

    @Test func 考え中に話し始めたら割り込みを通知して聞き直す() async {
        let h = ConversationHarness()
        #expect(await h.sayAndFinish("先生、これ") == .userTurnAccepted("先生、これ"))
        h.controller.handle(.voiceStarted)
        #expect(await h.nextEvent() == .bargeIn(during: .thinking))
        #expect(h.controller.state == .listening)
        // 古い応答は話さない
        #expect(await h.controller.speak("どれどれ") == .rejected)

        h.controller.handle(.transcript("あ、やっぱりこっち"))
        h.controller.handle(.voiceEnded)
        h.clock.advance(by: .milliseconds(700))
        #expect(await h.nextEvent() == .userTurnAccepted("あ、やっぱりこっち"))
    }

    // MARK: - 発話中はマイクを止めるモード

    @Test func ミュートモードでは発話中にマイクを止め終わったら戻す() async {
        let h = ConversationHarness(settings: ConversationSettings(speakingInputMode: .muteWhileSpeaking))
        h.output.holdsPlayback = true
        let speaking = Task { await h.controller.speak("じゃあ読んでみるね") }
        await h.output.waitUntilSpeaking()
        #expect(h.input.mutedHistory == [true])

        // 止まりきる前に届いた入力は捨てる
        h.controller.handle(.voiceStarted)
        h.controller.handle(.transcript("じゃあ"))
        h.controller.handle(.voiceEnded)
        #expect(h.controller.state == .speaking)

        h.output.finishCurrent()
        #expect(await speaking.value == .completed)
        #expect(h.controller.state == .idle)
        #expect(h.input.mutedHistory == [true, false])

        // 発話後は 30 秒ルールで続きを聞ける
        #expect(await h.sayAndFinish("読めた！") == .userTurnAccepted("読めた！"))
    }

    @Test func ミュートモードでもセッションを止めたらマイクを戻す() async {
        let h = ConversationHarness(settings: ConversationSettings(speakingInputMode: .muteWhileSpeaking))
        h.output.holdsPlayback = true
        let speaking = Task { await h.controller.speak("この問題はね") }
        await h.output.waitUntilSpeaking()
        h.controller.stop()
        #expect(h.controller.state == .idle)
        #expect(h.input.mutedHistory == [true, false])
        h.output.finishCurrent()
        #expect(await speaking.value == .interrupted)
        #expect(h.controller.state == .idle)
    }
}

struct CallWordAddressingJudgeTests {
    @Test(arguments: [
        "ねえ先生、これ教えて",
        "ねえ、先生",
        "ねぇ先生",
        "先生！",
        "せんせい、見て",
        " 先生ちょっと",
        "「先生」",
        "ねえ せんせい",
    ])
    func 呼びかけ語で始まる発話を呼びかけとみなす(utterance: String) {
        #expect(CallWordAddressingJudge.startsWithCallWord(utterance, callWords: ConversationSettings.defaultCallWords))
    }

    @Test(arguments: [
        "ねえ、これ見て",
        "これ先生に聞こう",
        "お母さん",
        "",
    ])
    func 呼びかけ語で始まらない発話は呼びかけではない(utterance: String) {
        #expect(!CallWordAddressingJudge.startsWithCallWord(utterance, callWords: ConversationSettings.defaultCallWords))
    }

    @Test func 空の呼びかけ語は無視する() {
        #expect(!CallWordAddressingJudge.startsWithCallWord("なんでも", callWords: ["", "、"]))
    }
}
