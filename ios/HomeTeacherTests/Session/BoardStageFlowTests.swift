import Foundation
import Testing
@testable import HomeTeacher

/// 黒板をしまうタイミングをセッションの流れで確かめる（#105）
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct BoardStageFlowTests {
    private static let cardsBoard = #"{"title":"考える順番","component":{"type":"step_cards","steps":[{"heading":"もとにする量","detail":"1200円"},{"heading":"割合","detail":"25%"}]}}"#

    private func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "BoardStageFlowTests-\(UUID().uuidString)"))
    }

    private func startSession(_ h: SessionHarness) async {
        await h.enqueueReply(["こんにちは！"])
        await h.coordinator.start()
        _ = await eventually { h.coordinator.completedReplies >= 1 && h.coordinator.conversationState == .idle }
    }

    /// 返事を1つ話し終えるまで待つ
    private func reply(_ h: SessionHarness, to utterance: String, with lines: [String]) async {
        let before = h.coordinator.completedReplies
        await h.enqueueReply(lines)
        await h.say(utterance)
        _ = await eventually { h.coordinator.completedReplies > before && h.coordinator.conversationState == .idle }
    }

    @Test func 会話の図は図を使わない返事が2回続いたらしまって先生だけにする() async throws {
        let h = try SessionHarness()
        await startSession(h)
        await h.transport.enqueue(.lines, "/v1/claude", body: SSEFixture.toolStream(text: "", name: "show_board", inputJSON: Self.cardsBoard))
        await reply(h, to: "ねえ先生、どうやって考えればいい？", with: ["黒板を見てね。", "まず、もとにする量はどれかな？"])
        #expect(h.coordinator.board != nil)

        // 図を見ながらの返事が1回なら、まだ出しておく
        await reply(h, to: "ねえ先生、1200円かな", with: ["そうそう、いいね。"])
        #expect(h.coordinator.board != nil)

        // 2回続いたら話題が移ったとみなしてしまう
        await reply(h, to: "ねえ先生、昨日サッカーしたよ", with: ["お、いいね！"])
        #expect(h.coordinator.board == nil)
        #expect(h.coordinator.boardReveal == nil)
    }

    @Test func 写真の分析の図は返事が続いてもしまわず休憩のあいだ預かって出し直す() async throws {
        let analysis = ProblemAnalyzerTests.response(blocks: [
            ProblemAnalyzerTests.toolUse("report_analysis", ProblemAnalyzerTests.thinkingInput),
            ProblemAnalyzerTests.toolUse("show_board", Self.cardsBoard, id: "toolu_2"),
        ])
        let preferences = SessionPreferences(defaults: try defaults())
        preferences.focusMinutes = 15
        preferences.breakMinutes = 5
        let h = try SessionHarness(preferences: preferences, camera: MockCamera())
        await startSession(h)
        await h.enqueueReply(["お、どれどれ。"])
        await h.transport.enqueue(.data, "/v1/claude", body: analysis)
        await h.enqueueReply(["割合の問題だね。"])
        await h.say("ねえ先生、これ見て")
        #expect(await eventually { h.voice.spoken.last == "割合の問題だね。" && h.coordinator.conversationState == .idle })
        #expect(h.coordinator.boardReveal?.pace == .hintStage)

        await reply(h, to: "ねえ先生、うーん", with: ["どこを見ればいいかな？"])
        await reply(h, to: "ねえ先生、ちょっと待って", with: ["うん、ゆっくりでいいよ。"])
        #expect(h.coordinator.board != nil)
        let shownBeforeBreak = h.coordinator.boardReveal?.shown

        // 休憩に入るとしまう
        h.clock.advance(by: .minutes(15))
        #expect(await eventually { h.coordinator.sessionMode == .rest })
        #expect(h.coordinator.board == nil)

        // 休憩が終わると、見せていたところまで出し直す
        h.clock.advance(by: .minutes(5))
        #expect(await eventually { h.coordinator.sessionMode == .study })
        guard case .component("考える順番", .stepCards)? = h.coordinator.board else {
            Issue.record("休憩のあとに図が戻っていない: \(String(describing: h.coordinator.board))")
            return
        }
        #expect(h.coordinator.boardReveal?.pace == .hintStage)
        #expect(h.coordinator.boardReveal?.shown == shownBeforeBreak)
    }

    @Test func 会話の図は休憩でしまって戻さない() async throws {
        let preferences = SessionPreferences(defaults: try defaults())
        preferences.focusMinutes = 15
        let h = try SessionHarness(preferences: preferences)
        await startSession(h)
        await h.transport.enqueue(.lines, "/v1/claude", body: SSEFixture.toolStream(text: "", name: "show_board", inputJSON: Self.cardsBoard))
        await reply(h, to: "ねえ先生、どうやって考えればいい？", with: ["黒板を見てね。"])
        #expect(h.coordinator.board != nil)

        h.clock.advance(by: .minutes(15))
        #expect(await eventually { h.coordinator.sessionMode == .rest })
        #expect(h.coordinator.board == nil)
        h.clock.advance(by: .minutes(5))
        #expect(await eventually { h.coordinator.sessionMode == .study })
        #expect(h.coordinator.board == nil)
    }
}
