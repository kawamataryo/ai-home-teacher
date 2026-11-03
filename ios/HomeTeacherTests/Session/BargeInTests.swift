import Foundation
import Testing
@testable import HomeTeacher

/// 割り込み（#13）の、履歴を切り詰める位置の計算。
struct ReplyTruncationTests {
    private func snapshot(_ finished: [String], current: String? = nil, played: Int = 0) -> SpokenSnapshot {
        SpokenSnapshot(finished: finished, current: current, playedInCurrent: played)
    }

    @Test func 話し終えた文と途中の文の文字数で切る() {
        let text = "まず問題を読もう。何を聞かれてるかな？"
        // 文の間に何もないときは、足し算と同じ
        #expect(ReplyTruncation.characterCount(in: text, spoken: snapshot(["まず問題を読もう。"], current: "何を聞かれてるかな？", played: 2)) == 11)
        #expect("まず問題を読もう。".count + 2 == 11)
    }

    @Test func 文の間の改行も数えて位置がずれない() {
        // SentenceSplitter は改行で区切って落とすので、文の文字数を足すだけだと 1 文字足りない
        let text = "うん。\nそうだね、まずは表を見よう。"
        let spoken = snapshot(["うん。"], current: "そうだね、まずは表を見よう。", played: 4)
        let count = ReplyTruncation.characterCount(in: text, spoken: spoken)
        #expect(count == 8)
        #expect(String(text.prefix(count)) == "うん。\nそうだね")
        let naive = "うん。".count + 4
        #expect(String(text.prefix(naive)) != "うん。\nそうだね")
    }

    @Test func 途中の文をまだ話し始めていなければ前の文までで切る() {
        let text = "いいね！どこがむずかしい？"
        #expect(ReplyTruncation.characterCount(in: text, spoken: snapshot(["いいね！"], current: "どこがむずかしい？", played: 0)) == 4)
        #expect(ReplyTruncation.characterCount(in: text, spoken: snapshot([], current: "いいね！", played: 0)) == 0)
    }

    @Test func 最後が先生の発言でなければ切らない() {
        // まだ 1 文字も届いていない（最後は子どもの発話）。最後の先生の発言は前の返事なので残す
        let messages = [
            ChatMessage(role: .assistant, content: [.text("こんにちは！")]),
            ChatMessage(role: .user, content: [.text("ねえ先生")]),
        ]
        #expect(ReplyTruncation.targetCount(messages: messages, spoken: snapshot([])) == nil)
    }

    @Test func 全部話していたら切らない() {
        let messages = [ChatMessage(role: .assistant, content: [.text("うん。そうそう。")])]
        #expect(ReplyTruncation.targetCount(messages: messages, spoken: snapshot(["うん。", "そうそう。"])) == nil)
        #expect(ReplyTruncation.targetCount(messages: messages, spoken: snapshot(["うん。"])) == 3)
    }

    @Test func 最後のメッセージにない文は飛ばす() {
        // ツールの呼び出しをはさむと、先に話した文は前のメッセージにある
        let text = "大丈夫だよ。ゆっくりでいいからね。"
        let spoken = snapshot(["そっか。", "大丈夫だよ。"], current: "ゆっくりでいいからね。", played: 3)
        #expect(ReplyTruncation.characterCount(in: text, spoken: spoken) == 9)
    }
}

/// 割り込みを、まとめ役を通して確かめる。
@MainActor
struct BargeInTests {
    private func startSession(_ h: SessionHarness) async {
        await h.enqueueReply(["こんにちは！"])
        await h.coordinator.start()
        _ = await eventually { h.coordinator.completedReplies >= 1 && h.coordinator.conversationState == .idle }
    }

    @Test func 発話中に割り込まれたら話したところまでで履歴を切る() async throws {
        let h = try SessionHarness()
        await startSession(h)
        h.voice.holdsPlayback = true
        await h.enqueueReply(["まず問題を読もう。\n", "何を聞かれてるかな？", "表のどこを見る？"])

        await h.say("ねえ先生、これわかんない")
        #expect(await eventually { h.voice.spoken.count == 2 })
        h.voice.finishCurrent()
        #expect(await eventually { h.voice.spoken.count == 3 })

        // 2 文目の 2 文字目まで話したところで割り込む
        h.voice.playedCharactersOnStop = 2
        h.input.send(.voiceStarted)
        #expect(await eventually { await h.lastAssistantText() == "まず問題を読もう。\n何を" })
        #expect(h.voice.spoken.last == "何を聞かれてるかな？")
        #expect(h.avatarState == .listening)

        // 次の返事のリクエストには、切り詰めた履歴が入る
        await h.enqueueReply(["うん、どこ？"])
        h.input.send(.transcript("待って"))
        h.input.send(.voiceEnded)
        for _ in 0..<50 where h.coordinator.controller?.state == .listening {
            h.clock.advance(by: .milliseconds(700))
            try await Task.sleep(for: .milliseconds(5))
        }
        h.voice.holdsPlayback = false
        h.voice.finishCurrent()
        #expect(await eventually { h.voice.spoken.last == "うん、どこ？" })
        let messages = try #require(await h.conversationRequests().last?["messages"] as? [[String: Any]])
        let texts = messages.compactMap { ($0["content"] as? [[String: Any]])?.first?["text"] as? String }
        #expect(texts.suffix(3) == ["ねえ先生、これわかんない", "まず問題を読もう。\n何を", "待って"])
    }

    @Test func ストリームの途中で割り込まれたら止めてから切る() async throws {
        let h = try SessionHarness()
        await startSession(h)
        h.voice.holdsPlayback = true
        // 1 文目のあとの文字が届いたところで、通信が続いたままになる
        await h.transport.enqueue(.lines, "/v1/claude", [.partial(SSEFixture.partialTextStream(["まず問題を読もう。", "何を"]))])

        await h.say("ねえ先生、これ見て")
        #expect(await eventually { h.voice.spoken.count == 2 })
        h.voice.playedCharactersOnStop = 3
        h.input.send(.voiceStarted)
        #expect(await eventually { await h.lastAssistantText() == "まず問" })
        // ストリームは止めたので、あとから文字が足されない
        try await Task.sleep(for: .milliseconds(50))
        #expect(await h.lastAssistantText() == "まず問")
    }

    @Test func 文字が届く前の割り込みでは前の返事を消さない() async throws {
        let h = try SessionHarness()
        await startSession(h)
        await h.transport.enqueue(.lines, "/v1/claude", [.hang])

        await h.say("ねえ先生、これ見て")
        #expect(await eventually { h.coordinator.conversationState == .thinking })
        h.input.send(.voiceStarted)
        #expect(await eventually { h.coordinator.conversationState == .listening })
        try await Task.sleep(for: .milliseconds(50))
        #expect(await h.lastAssistantText() == "こんにちは！")
    }

    @Test func マイクを止める設定では先生が話している間マイクを止める() async throws {
        let defaults = try #require(UserDefaults(suiteName: "BargeInTests-\(UUID().uuidString)"))
        let preferences = SessionPreferences(defaults: defaults)
        preferences.speakingInputMode = .muteWhileSpeaking
        let h = try SessionHarness(preferences: preferences)
        await startSession(h)

        #expect(h.coordinator.controller?.settings.speakingInputMode == .muteWhileSpeaking)
        #expect(h.input.mutedHistory == [true, false])
    }

    @Test func 設定は端末に保存される() throws {
        let defaults = try #require(UserDefaults(suiteName: "SessionPreferences-\(UUID().uuidString)"))
        #expect(SessionPreferences(defaults: defaults).speakingInputMode == .bargeIn)
        SessionPreferences(defaults: defaults).speakingInputMode = .muteWhileSpeaking
        #expect(SessionPreferences(defaults: defaults).speakingInputMode == .muteWhileSpeaking)
    }
}
