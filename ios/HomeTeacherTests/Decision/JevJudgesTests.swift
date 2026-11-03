import Foundation
import Testing
@testable import HomeTeacher

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct JevJudgesTests {
    private typealias Key = TeacherDecisions.Key

    private static func cache(_ answers: [String: Double]) -> UtteranceDecisionCache {
        DecisionFixture.cache(MockTransport(body: DecisionFixture.nouls(answers)))
    }

    private static var failing: UtteranceDecisionCache {
        DecisionFixture.cache(MockTransport(status: 500, body: ""))
    }

    // MARK: - まとめて先に聞く

    @Test func 同じ発話の判断は1回のリクエストを使い回す() async {
        let transport = MockTransport(body: DecisionFixture.nouls([Key.addressed: 0.9, Key.complete: 0.9, Key.capture: 0.1, Key.help: 0.1]))
        let cache = DecisionFixture.cache(transport)
        #expect(await JevEndOfUtteranceDecider(cache: cache).isUtteranceComplete("これってどうやるの"))
        // 確定したときの書き起こしは句読点や空白が揺れても同じ発話
        #expect(await JevAddressingJudge(cache: cache).isAddressedToTeacher("これって、どうやるの "))
        #expect(await JevCaptureRequestJudge(cache: cache).isCaptureRequest("これってどうやるの") == false)
        #expect(await transport.requests.count == 1)
        #expect(cache.requestCount == 1)
    }

    @Test func 状況が変われば聞き直す() async {
        let transport = MockTransport(responses: [
            .init(body: DecisionFixture.nouls([Key.addressed: 0.9])), .init(body: DecisionFixture.nouls([Key.addressed: 0.9])),
        ])
        let cache = DecisionFixture.cache(transport)
        _ = await cache.analysis(for: "うん").value
        cache.teacherLastSaid = "ちょっと見せて？"
        _ = await cache.analysis(for: "うん").value
        #expect(await transport.requests.count == 2)
    }

    @Test func 待ちきれなくてもリクエストは続けてあとで使う() async {
        let transport = SlowTransport(delay: .milliseconds(150), body: DecisionFixture.nouls([Key.addressed: 0.1, Key.complete: 0.9]))
        let cache = DecisionFixture.cache(transport)
        // 言い終わったかは短く待って諦める
        #expect(await JevEndOfUtteranceDecider(cache: cache, timeout: .milliseconds(20)).isUtteranceComplete("ママ、おやつまだ？") == false)
        // 確定したときは同じリクエストの答えを待つ
        #expect(await JevAddressingJudge(cache: cache).isAddressedToTeacher("ママ、おやつまだ？") == false)
        #expect(await transport.requestCount == 1)
        #expect(await transport.wasCancelled == false)
    }

    // MARK: - 先生への発話か

    @Test func 呼びかけ語があればJevに聞かずに受け付ける() async {
        let transport = MockTransport(responses: [])
        let judge = JevAddressingJudge(cache: DecisionFixture.cache(transport))
        #expect(await judge.isAddressedToTeacher("ねえ先生、これ教えて"))
        #expect(await transport.requests.isEmpty)
    }

    @Test(arguments: [(0.9, true), (0.5, true), (0.2, false)])
    func 先生への発話はいいえのときだけ聞き流す(_ p: Double, _ accepted: Bool) async {
        let judge = JevAddressingJudge(cache: Self.cache([Key.addressed: p]))
        #expect(await judge.isAddressedToTeacher("これってどうやるの") == accepted)
    }

    @Test func Jevが失敗したら声を無視せず受け付ける() async {
        #expect(await JevAddressingJudge(cache: Self.failing).isAddressedToTeacher("これってどうやるの"))
        let slow = JevAddressingJudge(cache: DecisionFixture.cache(SlowTransport()), timeout: .milliseconds(50))
        #expect(await slow.isAddressedToTeacher("これってどうやるの"))
    }

    @Test func 先生が最後に話した文をstateに入れる() async throws {
        let transport = MockTransport(body: DecisionFixture.nouls([Key.addressed: 0.9]))
        let judge = JevAddressingJudge(cache: DecisionFixture.cache(transport))
        judge.teacherLastSaid = "答えはいくつになったかな？"
        _ = await judge.isAddressedToTeacher("24")
        let state = try #require(try await DecisionFixture.requestJSON(transport)["state"] as? [String: String])
        #expect(state["teacher_last_said"] == "答えはいくつになったかな？")
    }

    // MARK: - 言い終わったか

    @Test(arguments: [(0.9, true), (0.8, true), (0.76, false), (0.1, false)])
    func 言い終わったのは高い確率のときだけ(_ p: Double, _ complete: Bool) async {
        let decider = JevEndOfUtteranceDecider(cache: Self.cache([Key.complete: p]))
        #expect(await decider.isUtteranceComplete("えっと、24かな") == complete)
    }

    @Test func 言い終わったかはJevが失敗したら無音に任せる() async {
        #expect(await JevEndOfUtteranceDecider(cache: Self.failing).isUtteranceComplete("答えは75%です") == false)
        let slow = JevEndOfUtteranceDecider(cache: DecisionFixture.cache(SlowTransport()), timeout: .milliseconds(50))
        #expect(await slow.isUtteranceComplete("答えは75%です") == false)
    }

    @Test func 言い終わったかの既定の待ち時間は無音の区切りより短い() {
        let decider = JevEndOfUtteranceDecider(cache: DecisionFixture.cache(MockTransport(responses: [])))
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
        // 言い方は依頼に見えても Jev がいいえと言えば違う（「見て見て、できた！」など）
        #expect(await JevCaptureRequestJudge(cache: Self.cache([Key.capture: 0.1])).isCaptureRequest("見て見て、できた！") == false)
        #expect(await JevCaptureRequestJudge(cache: Self.cache([Key.capture: 0.9])).isCaptureRequest("この問題") )
    }

    @Test func 撮影の依頼は迷う帯なら言い方で決める() async {
        #expect(await JevCaptureRequestJudge(cache: Self.cache([Key.capture: 0.5])).isCaptureRequest("ここわかんない"))
        #expect(await JevCaptureRequestJudge(cache: Self.cache([Key.capture: 0.5])).isCaptureRequest("できた") == false)
    }

    @Test func 撮影の依頼はJevが使えなければ言い方で決める() async {
        #expect(await JevCaptureRequestJudge(cache: Self.failing).isCaptureRequest("ここわかんない"))
        #expect(await JevCaptureRequestJudge(cache: Self.failing).isCaptureRequest("できた") == false)
    }

    // MARK: - 今、声をかけるべきか（規則だけ）

    @Test func 声をかける規則() {
        #expect(RuleNudgeJudge.shouldSpeakUp(NudgeContext(minutesStalled: 3, phase: .working)))
        #expect(RuleNudgeJudge.shouldSpeakUp(NudgeContext(minutesStalled: 2.5, phase: .working)) == false)
        #expect(RuleNudgeJudge.shouldSpeakUp(NudgeContext(minutesStalled: 10, phase: .onBreak)) == false)
        #expect(RuleNudgeJudge.shouldSpeakUp(NudgeContext(minutesStalled: 10, phase: .working, isFacePresent: false)) == false)
        #expect(RuleNudgeJudge.shouldSpeakUp(NudgeContext(minutesStalled: 10, phase: .working, minutesSinceTeacherSpoke: 0.5)) == false)
    }

    // MARK: - ConversationController に組み込んだとき

    @Test func Jevが言い終わったと言えば無音を待たずに受け付け先生への発話かは聞き直さない() async {
        let transport = MockTransport(responses: [.init(body: DecisionFixture.nouls([Key.complete: 0.95, Key.addressed: 0.9]))])
        let cache = DecisionFixture.cache(transport)
        let h = ConversationHarness(addressingJudge: JevAddressingJudge(cache: cache), endOfUtteranceDecider: JevEndOfUtteranceDecider(cache: cache))
        h.say("これってどうやるの")
        #expect(await h.nextEvent() == .userTurnAccepted("これってどうやるの"))
        #expect(await transport.requests.count == 1)
    }

    @Test func Jevが失敗したら無音のタイムアウトで区切る() async {
        let transport = MockTransport(status: 500, body: #"{"error":"upstream unreachable"}"#)
        let decider = ObservedEndOfUtteranceDecider(JevEndOfUtteranceDecider(cache: DecisionFixture.cache(transport)))
        let h = ConversationHarness(endOfUtteranceDecider: decider)
        h.say("ねえ先生、これ教えて")
        await decider.waitUntilAnswered()
        #expect(decider.results == [false])
        // Jev の返事が来ても、まだ区切らない
        #expect(h.controller.state == .listening)
        h.clock.advance(by: h.controller.settings.endOfUtteranceSilence)
        #expect(await h.nextEvent() == .userTurnAccepted("ねえ先生、これ教えて"))
    }

    @Test func Jevがいいえと言えば呼びかけ語のない発話は聞き流す() async {
        let h = ConversationHarness(addressingJudge: JevAddressingJudge(cache: Self.cache([Key.addressed: 0.1])))
        #expect(await h.sayAndFinish("ママ、おやつまだ？") == .utteranceIgnored("ママ、おやつまだ？"))
    }

    @Test func Jevが失敗しても呼びかけ語のない発話に応答する() async {
        let h = ConversationHarness(addressingJudge: JevAddressingJudge(cache: Self.failing))
        #expect(await h.sayAndFinish("これってどうやるの") == .userTurnAccepted("これってどうやるの"))
    }
}
