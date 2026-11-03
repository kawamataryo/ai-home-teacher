import Foundation
import Testing
@testable import HomeTeacher

/// 会話の途中で先生が出した図が黒板に届き、話している文に合わせて1つずつ見えること（#70）。
@MainActor
struct ConversationBoardTests {
    private static let cardsBoard = #"{"title":"考える順番","component":{"type":"step_cards","steps":[{"heading":"もとにする量","detail":"1200円"},{"heading":"割合","detail":"25%"},{"heading":"ということは？","detail":"はらうのは？"}]}}"#

    private func startSession(_ h: SessionHarness) async {
        await h.enqueueReply(["こんにちは！"])
        await h.coordinator.start()
        _ = await eventually { h.coordinator.completedReplies >= 1 && h.coordinator.conversationState == .idle }
    }

    @Test func 会話で出した図が黒板に出て文ごとに1枚ずつ増える() async throws {
        let h = try SessionHarness()
        await startSession(h)
        // 図を先に出し（言葉なし）、続きで3文話す
        await h.transport.enqueue(.lines, "/v1/claude", body: SSEFixture.toolStream(text: "", name: "show_board", inputJSON: Self.cardsBoard))
        await h.enqueueReply(["黒板を見てね。", "まず、もとにする量はどれかな？", "次は割合だよ。"])
        h.voice.holdsPlayback = true

        await h.say("ねえ先生、どうやって考えればいい？")
        #expect(await eventually { h.voice.spoken.last == "黒板を見てね。" })
        guard case .component("考える順番", .stepCards)? = h.coordinator.board else {
            Issue.record("手順カードが黒板に出ていない: \(String(describing: h.coordinator.board))")
            return
        }
        #expect(h.coordinator.boardReveal?.shown == 1)
        #expect(h.coordinator.boardReveal?.focus == 0)

        h.voice.finishCurrent()
        #expect(await eventually { h.voice.spoken.last == "まず、もとにする量はどれかな？" })
        #expect(h.coordinator.boardReveal?.shown == 2)

        h.voice.finishCurrent()
        #expect(await eventually { h.voice.spoken.last == "次は割合だよ。" })
        #expect(h.coordinator.boardReveal?.shown == 3)
        #expect(h.coordinator.boardReveal?.isComplete == true)
        h.voice.finishCurrent()

        // 次の返事のリクエストは、show_board の tool_use と tool_result が対になっている
        await h.enqueueReply(["いいね！"])
        h.voice.holdsPlayback = false
        await h.say("ねえ先生、わかった")
        #expect(await eventually { h.voice.spoken.last == "いいね！" })
        let request = try #require(await h.conversationRequests().last)
        let messages = try #require(request["messages"] as? [[String: Any]])
        let blocks = messages.flatMap { ($0["content"] as? [[String: Any]]) ?? [] }
        let toolUseIDs = blocks.filter { $0["type"] as? String == "tool_use" }.compactMap { $0["id"] as? String }
        let resultIDs = blocks.filter { $0["type"] as? String == "tool_result" }.compactMap { $0["tool_use_id"] as? String }
        #expect(toolUseIDs == ["toolu_1"])
        #expect(resultIDs == toolUseIDs)
        let tools = try #require(request["tools"] as? [[String: Any]])
        #expect(tools.compactMap { $0["name"] as? String }.contains("show_board"))
    }

    @Test func 割り込まれた返事の図は出さない() async throws {
        let h = try SessionHarness()
        await startSession(h)
        // 図が届く前に止まったままの返事
        await h.transport.enqueue(.lines, "/v1/claude", [.hang])
        await h.say("ねえ先生、どうやって考えればいい？")
        #expect(await eventually { h.coordinator.conversationState == .thinking })
        // 割り込み → 新しい返事（図なし）
        await h.enqueueReply(["うん、どうしたの？"])
        await h.say("ねえ先生、やっぱりいいや")
        #expect(await eventually { h.voice.spoken.last == "うん、どうしたの？" })
        #expect(h.coordinator.board == nil)
    }
}

/// 撮影の分析で出た図にも答えを書かない（#70）。
@MainActor
struct AnalysisBoardMaskTests {
    @Test func 分析の図に答えがあればそこだけはてなにしてヒントの段階に合わせて見せる() async throws {
        let leakyBoard = #"{"title":"面積の求め方","component":{"type":"step_cards","steps":[{"heading":"何を聞かれている？","detail":"長方形の面積"},{"heading":"かけ算","detail":"4×6＝24cm²"}]}}"#
        let analysis = ProblemAnalyzerTests.response(blocks: [
            ProblemAnalyzerTests.toolUse("report_analysis", ProblemAnalyzerTests.thinkingInput),
            ProblemAnalyzerTests.toolUse("show_board", leakyBoard, id: "toolu_2"),
        ])
        let camera = MockCamera()
        let h = try SessionHarness(camera: camera)
        await h.enqueueReply(["こんにちは！"])
        await h.coordinator.start()
        _ = await eventually { h.coordinator.completedReplies >= 1 && h.coordinator.conversationState == .idle }
        await h.enqueueReply(["お、どれどれ。"])
        await h.transport.enqueue(.data, "/v1/claude", body: analysis)
        await h.enqueueReply(["長方形の問題だね。"])

        await h.say("ねえ先生、これ見て")
        #expect(await eventually { h.voice.spoken.last == "長方形の問題だね。" })
        guard case .component(_, .stepCards(let cards))? = h.coordinator.board else {
            Issue.record("手順カードが出ていない: \(String(describing: h.coordinator.board))")
            return
        }
        #expect(cards.steps.map(\.detail) == ["長方形の面積", "？"])
        #expect(h.coordinator.boardReveal?.pace == .hintStage)
        #expect(h.coordinator.boardReveal?.shown == 1)

        // 「わかんない」でヒントの段階が進むと、カードも1枚増える
        await h.enqueueReply(["じゃあ、どこを見ればいいかな？"])
        await h.say("ねえ先生、わかんない")
        #expect(await eventually { h.voice.spoken.last == "じゃあ、どこを見ればいいかな？" })
        #expect(h.coordinator.boardReveal?.shown == 2)
    }
}
