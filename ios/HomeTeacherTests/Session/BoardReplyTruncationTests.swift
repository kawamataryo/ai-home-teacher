import Foundation
import Testing
@testable import HomeTeacher

/// 図を出した返事（図の前の文 → tool_use → tool_result → 続きの文）の途中で割り込んだときの切り詰め（#86）。
struct BoardReplyTruncationTests {
    static let toolUse = ContentBlock.toolUse(id: "toolu_b", name: "show_board", input: .object([:]))
    static let toolResult = ContentBlock.toolResult(toolUseID: "toolu_b", content: TeacherBrain.boardResultText)

    /// 前の返事 → 子どもの発話 → 図を出した返事
    private func boardReply(before: String = "図を見てね。", after: String? = "どっちかな？") -> ConversationHistory {
        var history = ConversationHistory()
        history.appendUser("（勉強スタート）")
        history.appendAssistantText("こんにちは！")
        history.appendUser("ねえ先生")
        history.appendAssistantText(before)
        history.append(.assistant, Self.toolUse)
        history.append(.user, Self.toolResult)
        if let after { history.appendAssistantText(after) }
        return history
    }

    private func snapshot(_ finished: [String], current: String? = nil, played: Int = 0) -> SpokenSnapshot {
        SpokenSnapshot(finished: finished, current: current, playedInCurrent: played)
    }

    /// 割り込みと同じ手順で切り詰める
    private func truncate(_ history: inout ConversationHistory, _ spoken: SpokenSnapshot) {
        if let count = ReplyTruncation.targetCount(history: history, spoken: spoken) {
            history.truncateLastReply(toCharacterCount: count)
        }
    }

    /// API が受け付ける形か: tool_use の次のメッセージ（user）の先頭に、同じ id の tool_result がそろっている。
    /// 役割は交互で、空のメッセージ・空の text がない
    static func expectValidPairing(_ messages: [ChatMessage], sourceLocation: SourceLocation = #_sourceLocation) {
        for (index, message) in messages.enumerated() {
            #expect(!message.content.isEmpty, "空のメッセージ: \(index)", sourceLocation: sourceLocation)
            for case .text(let text) in message.content {
                #expect(!text.isEmpty, "空の text: \(index)", sourceLocation: sourceLocation)
            }
            if index > 0 {
                #expect(messages[index - 1].role != message.role, "同じ役割が続く: \(index)", sourceLocation: sourceLocation)
            }
            let useIDs = message.content.compactMap { if case .toolUse(let id, _, _) = $0 { id } else { nil } }
            let resultIDs = message.content.compactMap { if case .toolResult(let id, _) = $0 { id } else { nil } }
            if !resultIDs.isEmpty {
                let previous = index > 0 ? messages[index - 1].content : []
                let previousUses = previous.compactMap { if case .toolUse(let id, _, _) = $0 { id } else { nil } }
                #expect(message.role == .user && previousUses == resultIDs, "tool_result が対になっていない: \(index)", sourceLocation: sourceLocation)
                // tool_result はメッセージの先頭に並べる
                let leading = message.content.prefix(resultIDs.count).allSatisfy { if case .toolResult = $0 { true } else { false } }
                #expect(leading, "tool_result が先頭にない: \(index)", sourceLocation: sourceLocation)
            }
            if !useIDs.isEmpty {
                let next = index + 1 < messages.count ? messages[index + 1].content : []
                let nextResults = next.compactMap { if case .toolResult(let id, _) = $0 { id } else { nil } }
                #expect(nextResults == useIDs, "tool_use に結果がない: \(index)", sourceLocation: sourceLocation)
            }
        }
    }

    @Test func 返事全体の文字は図の前の文と続きの文をつなげたもの() {
        let history = boardReply()
        #expect(history.lastReplyText == "図を見てね。どっちかな？")
        Self.expectValidPairing(history.messages)
    }

    @Test func 図の前の文の途中で割り込むとそこで切り続きは消す() {
        var history = boardReply()
        truncate(&history, snapshot([], current: "図を見てね。", played: 2))
        #expect(history.lastReplyText == "図を")
        #expect(history.lastAssistantText == "図を")
        // 図の呼び出しと結果は残り、続きの文は消える
        #expect(history.messages.suffix(2) == [
            ChatMessage(role: .assistant, content: [.text("図を"), Self.toolUse]),
            ChatMessage(role: .user, content: [Self.toolResult]),
        ])
        // 前の返事は変えない
        #expect(history.messages[1] == ChatMessage(role: .assistant, content: [.text("こんにちは！")]))
        Self.expectValidPairing(history.messages)
    }

    @Test func 図の前の文を話し始める前に割り込むと文を消して図の対だけ残す() {
        var history = boardReply()
        truncate(&history, snapshot([], current: "図を見てね。", played: 0))
        #expect(history.lastReplyText == "")
        #expect(history.messages.suffix(2) == [
            ChatMessage(role: .assistant, content: [Self.toolUse]),
            ChatMessage(role: .user, content: [Self.toolResult]),
        ])
        Self.expectValidPairing(history.messages)
    }

    @Test func 図を出した直後に割り込むと図の前の文は残し続きを消す() {
        var history = boardReply()
        // 図の前の文は話し終え、続きの文はまだ話し始めていない
        truncate(&history, snapshot(["図を見てね。"], current: "どっちかな？", played: 0))
        #expect(history.lastReplyText == "図を見てね。")
        #expect(history.messages.last == ChatMessage(role: .user, content: [Self.toolResult]))
        Self.expectValidPairing(history.messages)
    }

    @Test func 続きの文の途中で割り込むと続きをそこで切る() {
        var history = boardReply()
        truncate(&history, snapshot(["図を見てね。"], current: "どっちかな？", played: 3))
        #expect(history.lastReplyText == "図を見てね。どっち")
        #expect(history.messages.suffix(3) == [
            ChatMessage(role: .assistant, content: [.text("図を見てね。"), Self.toolUse]),
            ChatMessage(role: .user, content: [Self.toolResult]),
            ChatMessage(role: .assistant, content: [.text("どっち")]),
        ])
        Self.expectValidPairing(history.messages)
    }

    @Test func 全部話し終えていたら切らない() {
        let history = boardReply()
        #expect(ReplyTruncation.targetCount(history: history, spoken: snapshot(["図を見てね。", "どっちかな？"])) == nil)
    }

    @Test func 続きが届く前に割り込んでも図の前の文を切る() {
        // 続きのリクエストを待っている間（最後が tool_result）。以前はここで切れなかった
        var history = boardReply(before: "まず図を見よう。黒板に出すね。", after: nil)
        truncate(&history, snapshot(["まず図を見よう。"], current: "黒板に出すね。", played: 2))
        #expect(history.lastReplyText == "まず図を見よう。黒板")
        #expect(history.messages.last == ChatMessage(role: .user, content: [Self.toolResult]))
        Self.expectValidPairing(history.messages)
    }

    @Test func 言葉なしで図を出した返事の続きで割り込む() {
        var history = boardReply(before: "", after: "黒板を見てね。どこが同じかな？")
        truncate(&history, snapshot(["黒板を見てね。"], current: "どこが同じかな？", played: 2))
        #expect(history.lastReplyText == "黒板を見てね。どこ")
        #expect(history.messages.suffix(3) == [
            ChatMessage(role: .assistant, content: [Self.toolUse]),
            ChatMessage(role: .user, content: [Self.toolResult]),
            ChatMessage(role: .assistant, content: [.text("黒板を見てね。どこ")]),
        ])
        Self.expectValidPairing(history.messages)
    }

    @Test func 文の間の改行は図をまたいでも数える() {
        var history = boardReply(before: "うん。\n図を見て。\n", after: "\nどっち？")
        truncate(&history, snapshot(["うん。", "図を見て。"], current: "どっち？", played: 1))
        #expect(history.lastReplyText == "うん。\n図を見て。\n\nど")
        Self.expectValidPairing(history.messages)
    }

    @Test func 切り詰めたあとの子どもの発話はツールの結果のあとに入る() {
        var history = boardReply()
        truncate(&history, snapshot(["図を見てね。"]))
        history.appendUser("待って")
        #expect(history.messages.last == ChatMessage(role: .user, content: [Self.toolResult, .text("待って")]))
        Self.expectValidPairing(history.messages)
        // 次の割り込みでは、この返事はもう前の返事
        #expect(history.lastReplyText == "")
        history.truncateLastReply(toCharacterCount: 0)
        #expect(history.lastAssistantText == "図を見てね。")
    }

    @Test func 割り込みのどの位置でも対が保たれる() {
        let before = "図を見てね。上が元だよ。"
        let after = "どっちかな？下は？"
        let sentences = ["図を見てね。", "上が元だよ。", "どっちかな？", "下は？"]
        for finishedCount in 0..<sentences.count {
            let current = sentences[finishedCount]
            for played in 0...current.count {
                var history = boardReply(before: before, after: after)
                truncate(&history, snapshot(Array(sentences.prefix(finishedCount)), current: current, played: played))
                let expected = sentences.prefix(finishedCount).joined() + current.prefix(played)
                #expect(history.lastReplyText == expected, "\(finishedCount) 文 + \(played) 文字")
                Self.expectValidPairing(history.messages)
                #expect(history.messages.contains { $0.content.contains(Self.toolUse) })
            }
        }
    }

    @Test func 見せる前に止めた図はツールの結果を書き換える() {
        var history = boardReply()
        history.rewriteLastReplyToolResults { name, content in
            name == "show_board" ? TeacherBrain.boardNotShownText : content
        }
        #expect(history.messages[4] == ChatMessage(role: .user, content: [
            .toolResult(toolUseID: "toolu_b", content: TeacherBrain.boardNotShownText),
        ]))
        Self.expectValidPairing(history.messages)
    }
}

/// 図を出した返事の割り込みを、まとめ役を通して確かめる（#86）。
@MainActor
struct BoardReplyBargeInTests {
    private static let board = #"{"title":"考える順番","component":{"type":"step_cards","steps":[{"heading":"もとにする量","detail":"1200円"},{"heading":"割合","detail":"25%"}]}}"#

    private func startSession(_ h: SessionHarness) async {
        await h.enqueueReply(["こんにちは！"])
        await h.coordinator.start()
        _ = await eventually { h.coordinator.completedReplies >= 1 && h.coordinator.conversationState == .idle }
    }

    private func messages(_ h: SessionHarness) async -> [ChatMessage] {
        await h.coordinator.brain?.history.messages ?? []
    }

    @Test func 図の前の文の途中で割り込むと話したところで切り図の対は残す() async throws {
        let h = try SessionHarness()
        await startSession(h)
        h.voice.holdsPlayback = true
        await h.transport.enqueue(.lines, "/v1/claude", body: SSEFixture.toolStream(
            text: "まず問題を読もう。黒板を見てね。", toolID: "toolu_b", name: "show_board", inputJSON: Self.board
        ))
        await h.enqueueReply(["どっちがもとにする量かな？"])

        await h.say("ねえ先生、これわかんない")
        #expect(await eventually { h.voice.spoken.last == "まず問題を読もう。" })
        // 続きの文まで履歴に届くのを待つ（図は黒板に出ている）
        #expect(await eventually { await h.coordinator.brain?.history.lastReplyText.hasSuffix("かな？") == true })
        #expect(h.coordinator.board != nil)

        h.voice.playedCharactersOnStop = 2
        h.input.send(.voiceStarted)
        #expect(await eventually { await h.coordinator.brain?.history.lastReplyText == "まず" })
        let history = await messages(h)
        BoardReplyTruncationTests.expectValidPairing(history)
        let reply = history[history.count - 2]
        #expect(reply.role == .assistant)
        #expect(reply.content.first == .text("まず"))
        guard case .toolUse("toolu_b", "show_board", _)? = reply.content.last else {
            Issue.record("図の tool_use が残っていない: \(reply)")
            return
        }
        // 図は見せたので、結果はそのまま
        #expect(history.last == ChatMessage(role: .user, content: [.toolResult(toolUseID: "toolu_b", content: TeacherBrain.boardResultText)]))
    }

    @Test func 続きの文の途中で割り込むと続きを切る() async throws {
        let h = try SessionHarness()
        await startSession(h)
        h.voice.holdsPlayback = true
        await h.transport.enqueue(.lines, "/v1/claude", body: SSEFixture.toolStream(
            text: "黒板を見てね。", toolID: "toolu_b", name: "show_board", inputJSON: Self.board
        ))
        await h.enqueueReply(["どっちがもとにする量かな？"])

        await h.say("ねえ先生、これわかんない")
        #expect(await eventually { h.voice.spoken.last == "黒板を見てね。" })
        h.voice.finishCurrent()
        #expect(await eventually { h.voice.spoken.last == "どっちがもとにする量かな？" })
        h.voice.playedCharactersOnStop = 3
        h.input.send(.voiceStarted)
        #expect(await eventually { await h.coordinator.brain?.history.lastReplyText == "黒板を見てね。どっち" })
        let history = await messages(h)
        BoardReplyTruncationTests.expectValidPairing(history)
        #expect(history.last == ChatMessage(role: .assistant, content: [.text("どっち")]))
    }

    @Test func 図を見せる前に割り込むと結果を見せていないに書き換える() async throws {
        let h = try SessionHarness()
        await startSession(h)
        // 言葉なしで図を出し、続きのリクエストは返ってこない（図はまだ黒板に出ていない）
        await h.transport.enqueue(.lines, "/v1/claude", body: SSEFixture.toolStream(
            text: "", toolID: "toolu_b", name: "show_board", inputJSON: Self.board
        ))
        await h.transport.enqueue(.lines, "/v1/claude", [.hang])

        await h.say("ねえ先生、これわかんない")
        #expect(await eventually { await h.transport.count(.lines, "/v1/claude") == 3 })
        #expect(h.coordinator.board == nil)
        h.input.send(.voiceStarted)
        #expect(await eventually {
            await messages(h).last == ChatMessage(role: .user, content: [
                .toolResult(toolUseID: "toolu_b", content: TeacherBrain.boardNotShownText),
            ])
        })
        BoardReplyTruncationTests.expectValidPairing(await messages(h))
        #expect(h.coordinator.board == nil)
    }
}
