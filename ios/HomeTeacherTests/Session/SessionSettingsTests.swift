import Foundation
import Testing
@testable import HomeTeacher

/// 設定画面の残り（#65）：集中と休憩の分数・見守りの時間・声かけの言い回し。端末に保存し、次のセッションから効く
@MainActor
struct SessionSettingsTests {
    private func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "SessionSettingsTests-\(UUID().uuidString)"))
    }

    private func startSession(_ h: SessionHarness) async {
        await h.enqueueReply(["こんにちは！"])
        await h.coordinator.start()
        _ = await eventually { h.coordinator.completedReplies >= 1 && h.coordinator.conversationState == .idle }
    }

    @Test func 初期値は集中25分休憩5分見守り3分言い回しは定型句() throws {
        let preferences = SessionPreferences(defaults: try defaults())
        #expect(preferences.focusMinutes == 25)
        #expect(preferences.breakMinutes == 5)
        #expect(preferences.watchOverMinutes == 3)
        #expect(preferences.allowsNudgeVariation == false)
        #expect(preferences.timerSettings() == FocusTimerSettings())
    }

    @Test func 端末に保存され選択肢にない値は使わない() throws {
        let store = try defaults()
        let preferences = SessionPreferences(defaults: store)
        preferences.focusMinutes = 15
        preferences.breakMinutes = 10
        preferences.watchOverMinutes = 5
        preferences.allowsNudgeVariation = true

        let reloaded = SessionPreferences(defaults: store)
        #expect(reloaded.focusMinutes == 15)
        #expect(reloaded.breakMinutes == 10)
        #expect(reloaded.watchOverMinutes == 5)
        #expect(reloaded.allowsNudgeVariation)

        store.set(7, forKey: SessionPreferences.focusMinutesKey)
        store.set(99, forKey: SessionPreferences.breakMinutesKey)
        let fallback = SessionPreferences(defaults: store)
        #expect(fallback.focusMinutes == SessionPreferences.defaultFocusMinutes)
        #expect(fallback.breakMinutes == SessionPreferences.defaultBreakMinutes)
    }

    @Test func 設定を変えると次のセッションのタイマーと見守りと声かけに効く() async throws {
        let preferences = SessionPreferences(defaults: try defaults())
        let clock = ManualClock()
        // アプリと同じく、見守りはセッションを始めるときに設定を読む
        let watchOver = WatchOver(
            watcher: MockActivityWatcher(), clock: clock, configuration: { preferences.watchOverConfiguration },
            makeJudge: { RuleNudgeJudge(stalledMinutesThreshold: $0.stallMinutes) }
        )
        let h = try SessionHarness(preferences: preferences, clock: clock, watchOver: watchOver)
        await startSession(h)
        #expect(h.coordinator.timer?.settings == FocusTimerSettings())
        #expect(watchOver.detector?.configuration.stallMinutes == 3)

        // セッション中に変えても、いまのセッションは変わらない
        preferences.focusMinutes = 15
        preferences.breakMinutes = 10
        preferences.allowsNudgeVariation = true
        preferences.watchOverMinutes = 5
        #expect(h.coordinator.timer?.settings.focusDuration == .minutes(25))

        await h.coordinator.end()
        await startSession(h)
        let settings = try #require(h.coordinator.timer?.settings)
        #expect(settings.focusDuration == .minutes(15))
        #expect(settings.breakDuration == .minutes(10))
        #expect(settings.allowsVariation)
        // 5 分前の励ましはそのまま
        #expect(settings.encouragesBeforeFocusEnds)
        #expect(watchOver.detector?.configuration.stallMinutes == 5)
    }

    @Test func 言い回しを変える設定なら区切りで言い換えた声かけを話す() async throws {
        let preferences = SessionPreferences(defaults: try defaults())
        preferences.focusMinutes = 15
        preferences.allowsNudgeVariation = true
        let h = try SessionHarness(preferences: preferences)
        await startSession(h)

        // 励まし（あと5分）は言い換えに失敗して定型句のまま、区切りでは言い換える
        h.clock.advance(by: .minutes(10))
        #expect(await eventually { h.voice.spoken.last == FixedPhrase.fiveMinutesLeft.text })
        await h.transport.enqueue(.data, "/v1/claude", body: NudgeRephraserTests.response("よし、ちょっとひと休みしよう！"))
        h.clock.advance(by: .minutes(5))
        #expect(await eventually { h.voice.spoken.last == "よし、ちょっとひと休みしよう！" })
        #expect(h.coordinator.sessionMode == .rest)
    }

    @Test func 定型句の設定なら言い換えを頼まない() async throws {
        let preferences = SessionPreferences(defaults: try defaults())
        preferences.focusMinutes = 15
        let h = try SessionHarness(preferences: preferences)
        await startSession(h)
        let before = await h.transport.count(.data, "/v1/claude")

        h.clock.advance(by: .minutes(15))
        #expect(await eventually { h.voice.spoken.last == FixedPhrase.breakTime.text })
        #expect(await h.transport.count(.data, "/v1/claude") == before)
    }
}

struct NudgeRephraserTests {
    static func response(_ text: String) -> String {
        SSEFixture.json([
            "id": "msg_1", "type": "message", "role": "assistant", "stop_reason": "end_turn",
            "content": [["type": "text", "text": text]],
        ])
    }

    @Test func 場面といつもの言い方をHaikuに渡す() throws {
        let rephraser = NudgeRephraser(client: WorkerClient(baseURL: URL(string: "https://example.workers.dev")!, familyToken: "t"))
        let request = try rephraser.makeRequest(TeacherNudge(.breakTime, allowsVariation: true))
        #expect(request.model == .haiku)
        #expect(!request.stream)
        #expect(request.system.contains("同じ意味のまま"))
        #expect(request.messages.first?.text.contains("そろそろ休憩しよっか") == true)
    }

    @Test func 使えない言い換えは捨てる() {
        let breakTime = TeacherNudge(.breakTime, allowsVariation: true)
        #expect(NudgeRephraser.validated("「休けいしよっか！」", for: breakTime) == "休けいしよっか！")
        #expect(NudgeRephraser.validated("[praise]休けいしよっか！", for: breakTime) == "休けいしよっか！")
        #expect(NudgeRephraser.validated("", for: breakTime) == nil)
        #expect(NudgeRephraser.validated("休けい。\nそのあと算数", for: breakTime) == nil)
        #expect(NudgeRephraser.validated(String(repeating: "あ", count: 41), for: breakTime) == nil)
        // 残り時間の数字が消えたら意味が変わる
        let fiveLeft = TeacherNudge(.fiveMinutesLeft, allowsVariation: true)
        #expect(NudgeRephraser.validated("もう少しだよ、がんばろう！", for: fiveLeft) == nil)
        #expect(NudgeRephraser.validated("あと5分、ラストスパート！", for: fiveLeft) == "あと5分、ラストスパート！")
    }

    @Test func 言い換えを受け取る() async {
        let transport = MockTransport(body: Self.response("ちょっとひと休みしよう！"))
        let rephraser = NudgeRephraser(client: WorkerClient(baseURL: URL(string: "https://example.workers.dev")!, familyToken: "t", transport: transport))
        #expect(await rephraser.rephrase(TeacherNudge(.breakTime, allowsVariation: true)) == "ちょっとひと休みしよう！")
    }

    @Test func 失敗や時間切れならnil() async {
        let failing = NudgeRephraser(client: WorkerClient(baseURL: URL(string: "https://example.workers.dev")!, familyToken: "t", transport: MockTransport(status: 500, body: "{}")))
        #expect(await failing.rephrase(TeacherNudge(.breakTime, allowsVariation: true)) == nil)
        let hangingTransport = RoutingTransport()
        await hangingTransport.enqueue(.data, "/v1/claude", [.hang])
        let hanging = NudgeRephraser(
            client: WorkerClient(baseURL: URL(string: "https://example.workers.dev")!, familyToken: "t", transport: hangingTransport),
            timeout: .milliseconds(50)
        )
        #expect(await hanging.rephrase(TeacherNudge(.breakTime, allowsVariation: true)) == nil)
    }
}
