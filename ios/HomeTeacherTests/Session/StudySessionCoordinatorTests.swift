import Foundation
import Testing
@testable import HomeTeacher

/// 学習セッションのまとめ役を、音声なし（台本の入力・声のモック・Worker のモック）で通す。
@MainActor
struct StudySessionCoordinatorTests {
    private let previous = StudySessionRecord(
        id: "prev", startedAt: Date(timeIntervalSince1970: 1_792_900_000), endedAt: Date(timeIntervalSince1970: 1_792_902_000),
        focusMinutes: 30, summary: "割合の文章題に取り組んだ", teacherNote: "もとにする量を自分で見つけられた"
    )

    /// セッションを始めて、最初のひと言が終わるまで
    private func startSession(_ h: SessionHarness, opening: [String] = ["こんにちは！", "今日もがんばろう。"]) async {
        await h.enqueueReply(opening)
        await h.coordinator.start()
        _ = await eventually { h.coordinator.completedReplies >= 1 && h.coordinator.conversationState == .idle }
    }

    @Test func 始めると前回のことを入れて最初のひと言を話す() async throws {
        let h = try SessionHarness()
        try await h.store.saveSession(previous)
        await startSession(h)

        #expect(h.coordinator.phase == .active)
        #expect(h.voice.spoken == ["こんにちは！", "今日もがんばろう。"])
        #expect(h.coordinator.lastReplyFromWorker == true)
        let request = try #require(await h.conversationRequests().first)
        #expect(systemText(request)?.contains("割合の文章題に取り組んだ") == true)
        #expect(systemText(request)?.contains("勉強中") == true)
        let messages = try #require(request["messages"] as? [[String: Any]])
        let first = try #require((messages.first?["content"] as? [[String: Any]])?.first)
        #expect(first["text"] as? String == StudySessionCoordinator.openingTrigger)
        #expect(h.coordinator.timer?.status == .running)
    }

    @Test func 子どもの発話を受け付けたら先生の返事を文ごとに話す() async throws {
        let h = try SessionHarness()
        await startSession(h)
        await h.enqueueReply(["お、いいね！", "どこがむずかしい？"])

        await h.say("ねえ先生、割合がわかんない")
        #expect(await eventually { h.coordinator.completedReplies >= 2 })

        #expect(h.voice.spoken.suffix(2) == ["お、いいね！", "どこがむずかしい？"])
        let request = try #require(await h.conversationRequests().last)
        let messages = try #require(request["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["user", "assistant", "user"])
        let last = try #require((messages.last?["content"] as? [[String: Any]])?.first)
        #expect(last["text"] as? String == "ねえ先生、割合がわかんない")
        #expect(h.coordinator.caption == "ねえ先生、割合がわかんない")
    }

    @Test func 呼びかけがなく30秒を過ぎた発話には答えない() async throws {
        let h = try SessionHarness()
        await startSession(h)
        h.clock.advance(by: .seconds(31))

        await h.say("あーあ、つかれたな")
        #expect(await eventually { h.coordinator.conversationState == .idle })
        #expect(await h.conversationRequests().count == 1)
        #expect(h.voice.spoken.count == 2)
    }

    @Test func 返事を作れなかったら決まり文句で話す() async throws {
        let h = try SessionHarness()
        // 用意がないので Worker は 500 を返す
        await h.coordinator.start()
        #expect(await eventually { h.coordinator.completedReplies >= 1 })
        // つながらないので、端末の声で「調子が悪い」と伝えてから始める（#66）
        #expect(h.voice.spoken == [StudySessionCoordinator.troubleLine, StudySessionCoordinator.openingFallback])
        #expect(h.coordinator.lastReplyFromWorker == false)
        #expect(h.coordinator.connectionProblem == .server)
    }

    @Test func 話している途中で割り込まれたら残りの文は話さない() async throws {
        let h = try SessionHarness()
        await startSession(h)
        h.voice.holdsPlayback = true
        await h.enqueueReply(["まず問題を読もう。", "何を聞かれてるかな？"])

        await h.say("ねえ先生、これわかんない")
        #expect(await eventually { h.voice.spoken.count == 3 })
        #expect(h.coordinator.conversationState == .speaking)

        h.input.send(.voiceStarted)
        #expect(await eventually { h.voice.stopCount >= 1 })
        #expect(await eventually { h.coordinator.conversationState == .listening })
        h.voice.finishCurrent()
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.voice.spoken.last == "まず問題を読もう。")
        #expect(h.avatarState == .listening)
    }

    @Test func 考え中に話し始めたら作りかけの返事を捨てる() async throws {
        let h = try SessionHarness()
        await startSession(h)
        await h.transport.enqueue(.lines, "/v1/claude", [.hang])

        await h.say("ねえ先生、これ見て")
        #expect(await eventually { h.coordinator.conversationState == .thinking })
        h.input.send(.voiceStarted)
        #expect(await eventually { h.coordinator.conversationState == .listening })
        #expect(h.voice.spoken.count == 2)
        #expect(h.avatarState == .listening)
    }

    @Test func 終わりと言うとふり返りを話して保存し同期する() async throws {
        let h = try SessionHarness()
        await startSession(h)
        await h.transport.enqueue(.data, "/v1/claude", body: SessionReflectorTests.response(
            closing: "今日もよくがんばったね！また明日ね。"
        ))

        await h.say("終わり")
        #expect(await eventually(timeout: .seconds(5)) { h.coordinator.phase == .idle })

        #expect(h.voice.spoken.suffix(2) == [StudySessionCoordinator.reflectionFiller, "今日もよくがんばったね！また明日ね。"])
        let saved = try await h.store.recentSessions(limit: 5)
        #expect(saved.count == 1)
        #expect(saved.first?.summary.contains("割合") == true)
        #expect(await h.sync.reasons == [.sessionEnded])
        // ふり返りには会話の履歴を渡している
        let reflection = try #require(await h.transport.bodyData(.data, "/v1/claude").first)
        #expect(String(decoding: reflection, as: UTF8.self).contains("こんにちは"))
        #expect(h.coordinator.timer == nil)
    }

    @Test func ふり返りを作れなくても保存して決まり文句で終わる() async throws {
        let h = try SessionHarness()
        await startSession(h)
        await h.coordinator.end()

        #expect(h.coordinator.phase == .idle)
        #expect(h.voice.spoken.last == SessionReflector.fallback(for: .init(startedAt: .now, endedAt: .now, focusMinutes: 0, transcript: [], problems: [])).spokenClosing)
        #expect(try await h.store.recentSessions(limit: 5).count == 1)
        #expect(await h.sync.reasons == [.sessionEnded])
    }

    @Test func 休憩に入るとプロンプトを雑談モードに組み直す() async throws {
        var settings = StudySessionCoordinator.Settings()
        settings.timer = FocusTimerSettings(focusDuration: .seconds(60), breakDuration: .seconds(30), encouragesBeforeFocusEnds: false)
        let h = try SessionHarness(settings: settings)
        try await h.store.saveSession(previous)
        await startSession(h)

        h.clock.advance(by: .seconds(61))
        #expect(await eventually { h.coordinator.sessionMode == .rest })
        #expect(h.avatarState == .break)
        // 休憩の声かけ（定型句）を話し終えるのを待つ
        #expect(await eventually { h.voice.spoken.contains(FixedPhrase.breakTime.text) && h.coordinator.conversationState == .idle })

        await h.enqueueReply(["休憩だね、何してた？"])
        await h.say("ねえ先生、休憩だー")
        #expect(await eventually { h.voice.spoken.last == "休憩だね、何してた？" })
        let system = try #require(systemText(await h.conversationRequests().last))
        #expect(system.contains("休憩中"))
        #expect(system.contains("割合の文章題に取り組んだ"))
    }

    @Test func 待機中に勉強スタートと聞こえたら始める() async throws {
        let h = try SessionHarness()
        await h.enqueueReply(["よし、やろう！"])
        h.input.send(.voiceStarted)
        h.input.send(.transcript("勉強スタート"))
        #expect(await eventually { h.coordinator.phase == .active })
        #expect(await eventually { h.voice.spoken == ["よし、やろう！"] })
    }

    @Test func 会話の状態からアバターのできごとを決める() {
        typealias C = StudySessionCoordinator
        #expect(C.avatarEvents(from: .idle, to: .listening) == [.userStartedSpeaking])
        #expect(C.avatarEvents(from: .listening, to: .thinking) == [.thinkingStarted])
        #expect(C.avatarEvents(from: .thinking, to: .speaking) == [.speakingStarted(emotion: .neutral)])
        #expect(C.avatarEvents(from: .speaking, to: .idle) == [.speakingEnded])
        #expect(C.avatarEvents(from: .listening, to: .idle) == [.userStoppedSpeaking])
        var machine = AvatarStateMachine()
        machine.handle(.thinkingStarted)
        for event in C.avatarEvents(from: .thinking, to: .idle) { machine.handle(event) }
        #expect(machine.state == .idle)
    }
}

extension SessionHarness {
    var avatarState: AvatarState { coordinator.avatar.state }
}
