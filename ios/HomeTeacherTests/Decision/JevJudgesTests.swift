import Foundation
import Testing
@testable import HomeTeacher

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct JevJudgesTests {
    private typealias Key = TeacherDecisions.Key

    // MARK: - 先生への発話か

    @Test func 呼びかけ語があればJevに聞かずに受け付ける() async {
        let transport = MockTransport(responses: [])
        let judge = JevAddressingJudge(decisions: DecisionFixture.decisions(transport))
        #expect(await judge.isAddressedToTeacher("ねえ先生、これ教えて"))
        #expect(await transport.requests.isEmpty)
    }

    @Test func 呼びかけ語がなくてもJevが先生への発話と言えば受け付ける() async {
        let judge = JevAddressingJudge(decisions: DecisionFixture.decisions(MockTransport(body: DecisionFixture.noul(Key.addressed, 0.9))))
        #expect(await judge.isAddressedToTeacher("これってどうやるの"))
    }

    @Test func Jevが独り言と言えば無視する() async {
        let judge = JevAddressingJudge(decisions: DecisionFixture.decisions(MockTransport(body: DecisionFixture.noul(Key.addressed, 0.2))))
        #expect(await judge.isAddressedToTeacher("ママ、おやつまだ？") == false)
    }

    @Test func Jevが失敗したら呼びかけ語だけで決める() async {
        let judge = JevAddressingJudge(decisions: DecisionFixture.decisions(MockTransport(status: 500, body: "")))
        #expect(await judge.isAddressedToTeacher("これってどうやるの") == false)
    }

    @Test func Jevがタイムアウトしたら呼びかけ語だけで決める() async {
        let judge = JevAddressingJudge(decisions: DecisionFixture.decisions(SlowTransport()), timeout: .milliseconds(50))
        #expect(await judge.isAddressedToTeacher("これってどうやるの") == false)
    }

    // MARK: - 言い終わったか

    @Test func 言い終わった確率が高いときだけtrue() async {
        let high = JevEndOfUtteranceDecider(decisions: DecisionFixture.decisions(MockTransport(body: DecisionFixture.noul(Key.complete, 0.9))))
        #expect(await high.isUtteranceComplete("答えは75%です"))
        let middle = JevEndOfUtteranceDecider(decisions: DecisionFixture.decisions(MockTransport(body: DecisionFixture.noul(Key.complete, 0.6))))
        #expect(await middle.isUtteranceComplete("えっと、これは") == false)
    }

    @Test func 言い終わったかはJevが失敗したら無音に任せる() async {
        let failed = JevEndOfUtteranceDecider(decisions: DecisionFixture.decisions(MockTransport(status: 500, body: "")))
        #expect(await failed.isUtteranceComplete("答えは75%です") == false)
        let slow = JevEndOfUtteranceDecider(decisions: DecisionFixture.decisions(SlowTransport()), timeout: .milliseconds(50))
        #expect(await slow.isUtteranceComplete("答えは75%です") == false)
    }

    @Test func 言い終わったかの既定のタイムアウトは無音の区切りより短い() {
        let decider = JevEndOfUtteranceDecider(decisions: DecisionFixture.decisions(MockTransport(responses: [])))
        #expect(decider.timeout < ConversationSettings().endOfUtteranceSilence)
    }

    // MARK: - 撮影の依頼か

    @Test(arguments: ["これ見て", "ここ、わかんない", "先生 見てほしい", "ちょっとみて！", "問題見せるね"])
    func 撮影の依頼の言い方(_ utterance: String) {
        #expect(CaptureRequestDetector.matches(utterance))
    }

    @Test(arguments: ["できた", "75パーセント", "休憩したい"])
    func 撮影の依頼でない言い方(_ utterance: String) {
        #expect(CaptureRequestDetector.matches(utterance) == false)
    }

    @Test func 撮影の依頼はJevの答えを使う() async {
        let judge = JevCaptureRequestJudge(decisions: DecisionFixture.decisions(MockTransport(body: DecisionFixture.noul(Key.capture, 0.1))))
        // 言い方は依頼に見えても Jev が違うと言えば違う（「見て見て、できた！」など）
        #expect(await judge.isCaptureRequest("見て見て、できた！") == false)
    }

    @Test func 撮影の依頼はJevが使えなければ言い方で決める() async {
        let judge = JevCaptureRequestJudge(decisions: DecisionFixture.decisions(MockTransport(status: 500, body: "")))
        #expect(await judge.isCaptureRequest("ここわかんない"))
        let judge2 = JevCaptureRequestJudge(decisions: DecisionFixture.decisions(MockTransport(status: 500, body: "")))
        #expect(await judge2.isCaptureRequest("できた") == false)
    }

    // MARK: - 今、声をかけるべきか

    @Test func 声をかけるかはJevの答えを使う() async {
        let judge = JevNudgeJudge(decisions: DecisionFixture.decisions(MockTransport(body: DecisionFixture.noul(Key.nudge, 0.2))))
        #expect(await judge.shouldSpeakUp(NudgeContext(minutesStalled: 5, phase: .working)) == false)
    }

    @Test func 声をかけるかはJevが使えなければ規則で決める() async {
        let judge = JevNudgeJudge(decisions: DecisionFixture.decisions(MockTransport(status: 500, body: "")))
        #expect(await judge.shouldSpeakUp(NudgeContext(minutesStalled: 3, phase: .working)))
    }

    @Test func 声をかける規則() {
        #expect(JevNudgeJudge.ruleShouldSpeakUp(NudgeContext(minutesStalled: 3, phase: .working)))
        #expect(JevNudgeJudge.ruleShouldSpeakUp(NudgeContext(minutesStalled: 2.5, phase: .working)) == false)
        #expect(JevNudgeJudge.ruleShouldSpeakUp(NudgeContext(minutesStalled: 10, phase: .onBreak)) == false)
        #expect(JevNudgeJudge.ruleShouldSpeakUp(NudgeContext(minutesStalled: 10, phase: .working, isFacePresent: false)) == false)
        #expect(JevNudgeJudge.ruleShouldSpeakUp(NudgeContext(minutesStalled: 10, phase: .working, minutesSinceTeacherSpoke: 0.5)) == false)
    }

    // MARK: - 発話の意図

    @Test func 意図はJevの選択を使う() async {
        let body = DecisionFixture.choice(Key.intent, "雑談", probabilities: ["雑談": 0.7, "その他": 0.3])
        let classifier = JevIntentClassifier(decisions: DecisionFixture.decisions(MockTransport(body: body)))
        #expect(await classifier.intent("昨日サッカーしたんだ") == .smallTalk)
    }

    @Test func 意図はJevが使えなければ言い方で決める() async {
        let classifier = JevIntentClassifier(decisions: DecisionFixture.decisions(MockTransport(responses: [
            .init(status: 500, body: ""), .init(status: 500, body: ""), .init(status: 500, body: ""), .init(status: 500, body: ""),
        ])))
        #expect(await classifier.intent("もう終わりにしたい") == .wantsToFinish)
        #expect(await classifier.intent("ちょっと休憩したい") == .wantsBreak)
        #expect(await classifier.intent("これどうやって解くの？") == .question)
        #expect(await classifier.intent("75パーセント") == .other)
    }

    // MARK: - ConversationController に組み込んだとき

    @Test func Jevが言い終わったと言えば無音を待たずに受け付ける() async {
        let transport = MockTransport(responses: [.init(body: DecisionFixture.noul(Key.complete, 0.95))])
        let decider = JevEndOfUtteranceDecider(decisions: DecisionFixture.decisions(transport))
        let h = ConversationHarness(endOfUtteranceDecider: decider)
        h.say("ねえ先生、これ教えて")
        #expect(await h.nextEvent() == .userTurnAccepted("ねえ先生、これ教えて"))
        #expect(await transport.requests.count == 1)
    }

    @Test func Jevが失敗したら無音のタイムアウトで区切る() async {
        let transport = MockTransport(status: 500, body: #"{"error":"upstream unreachable"}"#)
        let decider = ObservedEndOfUtteranceDecider(JevEndOfUtteranceDecider(decisions: DecisionFixture.decisions(transport)))
        let h = ConversationHarness(endOfUtteranceDecider: decider)
        h.say("ねえ先生、これ教えて")
        await decider.waitUntilAnswered()
        #expect(decider.results == [false])
        // Jev の返事が来ても、まだ区切らない
        #expect(h.controller.state == .listening)
        h.clock.advance(by: h.controller.settings.endOfUtteranceSilence)
        #expect(await h.nextEvent() == .userTurnAccepted("ねえ先生、これ教えて"))
    }

    @Test func Jevが先生への発話と言えば呼びかけ語がなくても応答する() async {
        let transport = MockTransport(body: DecisionFixture.noul(Key.addressed, 0.9))
        let h = ConversationHarness(addressingJudge: JevAddressingJudge(decisions: DecisionFixture.decisions(transport)))
        #expect(await h.sayAndFinish("これってどうやるの") == .userTurnAccepted("これってどうやるの"))
    }

    @Test func Jevが失敗したら呼びかけ語のない発話は無視する() async {
        let transport = MockTransport(status: 500, body: "")
        let h = ConversationHarness(addressingJudge: JevAddressingJudge(decisions: DecisionFixture.decisions(transport)))
        #expect(await h.sayAndFinish("これってどうやるの") == .utteranceIgnored("これってどうやるの"))
        #expect(await h.sayAndFinish("先生、これってどうやるの") == .userTurnAccepted("先生、これってどうやるの"))
    }
}
