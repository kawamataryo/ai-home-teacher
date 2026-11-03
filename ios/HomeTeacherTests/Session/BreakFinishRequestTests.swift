import Foundation
import Testing
@testable import HomeTeacher

/// 「休憩したい」「終わりたい」を Jev で拾い、タイマーと終わりの確認につなぐ（#103）
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct BreakFinishRequestTests {
    private typealias Key = TeacherDecisions.Key

    private func startSession(_ h: SessionHarness) async {
        await h.enqueueReply(["こんにちは！"])
        await h.coordinator.start()
        _ = await eventually { h.coordinator.completedReplies >= 1 && h.coordinator.conversationState == .idle }
    }

    /// 発話 1 つ分の Jev の答え
    private func enqueueDecision(_ h: SessionHarness, break breakRequest: Double = 0.02, finish: Double = 0.02) async {
        let body = DecisionFixture.nouls([
            Key.addressed: 0.95, Key.complete: 0.95, Key.capture: 0.02, Key.help: 0.02,
            Key.breakRequest: breakRequest, Key.finishRequest: finish,
        ])
        await h.transport.enqueue(.data, DecisionClient.path, body: body)
    }

    // MARK: - 休憩したい

    @Test func 休憩したいと言えば集中の途中でも休憩に入り雑談モードで返事する() async throws {
        let h = try SessionHarness(usesDecisions: true)
        await startSession(h)
        await enqueueDecision(h, break: 0.97)
        await h.enqueueReply(["いいよ、ちょっと休もう！"])

        await h.say("ねえ先生、疲れた、ちょっと休憩したい")
        #expect(await eventually { h.coordinator.completedReplies >= 2 && h.coordinator.conversationState == .idle })
        #expect(h.coordinator.timer?.phase == .rest)
        #expect(h.coordinator.sessionMode == .rest)
        // 返事を作る前に雑談モードのプロンプトに切り替えている
        let system = try #require(systemText(await h.conversationRequests().last))
        #expect(system.contains("休憩中"))
        // Jev へのリクエストは発話 1 つにつき 1 回
        #expect(await h.transport.count(.data, DecisionClient.path) == 1)
    }

    @Test func 休憩したいか迷うときはタイマーを変えない() async throws {
        let h = try SessionHarness(usesDecisions: true)
        await startSession(h)
        await enqueueDecision(h, break: 0.63)
        await h.enqueueReply(["そっか、疲れたね。あと少しだけやってみる？"])

        await h.say("ねえ先生、疲れた")
        #expect(await eventually { h.coordinator.completedReplies >= 2 && h.coordinator.conversationState == .idle })
        #expect(h.coordinator.timer?.phase == .focus)
        #expect(h.coordinator.sessionMode == .study)
    }

    @Test func Jevが使えなければ言い方で休憩に入る() async throws {
        let h = try SessionHarness()
        await startSession(h)
        await h.enqueueReply(["いいよ、休もう！"])

        await h.say("ねえ先生、ちょっと休みたい")
        #expect(await eventually { h.coordinator.completedReplies >= 2 && h.coordinator.conversationState == .idle })
        #expect(h.coordinator.timer?.phase == .rest)
    }

    // MARK: - 終わりたい

    @Test func 終わりたいと言えば確かめてうんで終える() async throws {
        let h = try SessionHarness(usesDecisions: true)
        await startSession(h)
        await enqueueDecision(h, finish: 0.97)

        await h.say("ねえ先生、もう今日は終わりにしたい")
        #expect(await eventually { h.voice.spoken.last == StudySessionCoordinator.finishConfirmLine })
        #expect(h.coordinator.phase == .active)
        // 確かめただけで、Claude には聞いていない
        #expect(await h.transport.count(.lines, "/v1/claude") == 1)

        await enqueueDecision(h)
        await h.transport.enqueue(.data, "/v1/claude", body: SessionReflectorTests.response(closing: "今日もよくがんばったね！"))
        _ = await eventually { h.coordinator.conversationState == .idle }
        await h.say("うん")
        #expect(await eventually(timeout: .seconds(5)) { h.coordinator.phase == .idle })
        #expect(h.voice.spoken.last == "今日もよくがんばったね！")
    }

    @Test func 確かめてまだやると言えば続ける() async throws {
        let h = try SessionHarness(usesDecisions: true)
        await startSession(h)
        await enqueueDecision(h, finish: 0.95)
        await h.say("ねえ先生、今日はもうやめる")
        #expect(await eventually { h.voice.spoken.last == StudySessionCoordinator.finishConfirmLine })

        await enqueueDecision(h)
        await h.enqueueReply(["よし、もう1問いこう！"])
        _ = await eventually { h.coordinator.conversationState == .idle }
        await h.say("やっぱりまだやる")
        #expect(await eventually { h.voice.spoken.last == "よし、もう1問いこう！" })
        #expect(h.coordinator.phase == .active)
    }

    @Test func 終わりたいか迷うときは確かめずにふつうに返事する() async throws {
        let h = try SessionHarness(usesDecisions: true)
        await startSession(h)
        await enqueueDecision(h, finish: 0.51)
        await h.enqueueReply(["どうしたの？むずかしかった？"])
        await h.say("ねえ先生、もうやだ")
        // 返事は文ごとに話す
        #expect(await eventually { h.voice.spoken.last == "むずかしかった？" })
        #expect(!h.voice.spoken.contains(StudySessionCoordinator.finishConfirmLine))
    }

    // MARK: - 言い方の判定

    @Test(arguments: [("休憩したい", true), ("ちょっと休みたいな", true), ("疲れた", false), ("休み時間にドッジボールした", false)])
    func 休憩したいの言い方(_ utterance: String, _ expected: Bool) {
        #expect(BreakRequestDetector.isBreakRequest(utterance) == expected)
    }

    @Test(arguments: [
        ("うん", true), ("いいよ", true), ("うん、終わる", true), ("やめる", true),
        ("ううん", false), ("まだやる", false), ("もう1問やりたい", false), ("えっとね", false),
    ])
    func 終わりの確認への返事(_ utterance: String, _ agreed: Bool) {
        #expect(FinishConfirmationDetector.isAgreement(utterance) == agreed)
    }
}
