import Foundation
import Testing
@testable import HomeTeacher

/// Worker / Claude につながらない・遅い・途中で切れたときに固まらないこと（#66）。Worker のエラーはモックで再現する。
struct ConnectionProblemTests {
    @Test func エラーを理由に分ける() {
        #expect(ConnectionProblem(WorkerError.notConfigured) == .notConfigured)
        #expect(ConnectionProblem(WorkerError.http(status: 401, body: #"{"error":"unauthorized"}"#)) == .unauthorized)
        #expect(ConnectionProblem(WorkerError.http(status: 403, body: "")) == .unauthorized)
        #expect(ConnectionProblem(WorkerError.http(status: 502, body: "")) == .server)
        #expect(ConnectionProblem(TeacherBrainError.api(type: "overloaded_error", message: "Overloaded")) == .server)
        #expect(ConnectionProblem(URLError(.notConnectedToInternet)) == .offline)
        #expect(ConnectionProblem(URLError(.cannotConnectToHost)) == .offline)
        #expect(ConnectionProblem(URLError(.timedOut)) == .timeout)
        #expect(ConnectionProblem(DeadlineExceeded()) == .timeout)
        #expect(ConnectionProblem(DecisionError.timeout) == .timeout)
        #expect(ConnectionProblem(WorkerError.http(status: 400, body: "")) == .other)
    }

    @Test func 家族トークンの誤りは保護者にトークンの設定を案内する() {
        #expect(ConnectionProblem.unauthorized.parentMessage.contains("FAMILY_TOKEN"))
        #expect(ConnectionProblem.notConfigured.parentMessage.contains("Secrets.xcconfig"))
        #expect(ConnectionProblem.offline.parentMessage.contains("Wi-Fi"))
    }

    @Test func 設定がなければ通信せずにすぐ失敗する() async {
        #expect(AppConfig(infoDictionary: [:]) == nil)
        #expect(AppConfig(infoDictionary: ["WorkerBaseURL": "$(WORKER_BASE_URL)", "FamilyToken": "$(FAMILY_TOKEN)"]) == nil)
        await #expect(throws: WorkerError.notConfigured) {
            _ = try await WorkerClient.unconfigured.postJSON(path: "/v1/claude", body: Data())
        }
        await #expect(throws: WorkerError.notConfigured) {
            _ = try await WorkerClient.unconfigured.streamLines(path: "/v1/claude", body: Data())
        }
    }

    @MainActor
    @Test func 設定がなくてもアプリの土台を作れる() {
        let services = AppServices(config: nil)
        #expect(services.sync == nil)
        #expect(services.decisions == nil)
        #expect(services.client.transport is UnconfiguredTransport)
    }

    @MainActor
    @Test func 時間切れで止めて投げる() async {
        let clock = ManualClock()
        let task = Task { @MainActor in
            try await Deadline.run(.seconds(5), clock: clock) {
                try await Task.sleep(for: .seconds(3600))
                return 1
            }
        }
        try? await Task.sleep(for: .milliseconds(10))
        clock.advance(by: .seconds(5))
        await #expect(throws: DeadlineExceeded.self) { try await task.value }
        // 間に合えば値を返す
        let value = try? await Deadline.run(.seconds(5), clock: clock) { 42 }
        #expect(value == 42)
    }
}

@MainActor
struct ConnectionFailureFlowTests {
    private typealias C = StudySessionCoordinator

    private func startSession(_ h: SessionHarness) async {
        await h.enqueueReply(["こんにちは！"])
        await h.coordinator.start()
        _ = await eventually { h.coordinator.completedReplies >= 1 && h.coordinator.conversationState == .idle }
    }

    /// 返事が来ない間、少しずつ時計を進める
    private func advance(_ h: SessionHarness, by total: Duration, step: Duration = .milliseconds(500)) async {
        var elapsed = Duration.zero
        while elapsed < total {
            h.clock.advance(by: step)
            elapsed += step
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    @Test func 家族トークンの誤りでも固まらず端末の声で伝え保護者に案内する() async throws {
        let h = try SessionHarness()
        await startSession(h)
        await h.transport.enqueue(.lines, "/v1/claude", [.body(status: 401, #"{"error":"unauthorized"}"#)])

        await h.say("ねえ先生、これわかんない")
        #expect(await eventually { h.voice.spoken.suffix(2) == [C.troubleLine, C.replyFallback] })
        #expect(await eventually { h.coordinator.conversationState == .idle })
        #expect(h.coordinator.connectionProblem == .unauthorized)
        #expect(h.coordinator.lastReplyFromWorker == false)

        // つながったら案内を消す
        await h.enqueueReply(["うん、どこ？"])
        await h.say("ねえ先生")
        #expect(await eventually { h.voice.spoken.last == "うん、どこ？" })
        #expect(h.coordinator.connectionProblem == nil)
    }

    @Test func オフラインでも固まらない() async throws {
        let h = try SessionHarness()
        await startSession(h)
        await h.transport.enqueue(.lines, "/v1/claude", [.fail(.notConnectedToInternet)])

        await h.say("ねえ先生")
        #expect(await eventually { h.voice.spoken.suffix(2) == [C.troubleLine, C.replyFallback] })
        #expect(h.coordinator.connectionProblem == .offline)
        #expect(await eventually { h.coordinator.conversationState == .idle })
    }

    @Test func 設定がなければ通信せずに端末の声で始める() async throws {
        let h = try SessionHarness(client: .unconfigured)
        await h.coordinator.start()
        #expect(await eventually { h.coordinator.completedReplies >= 1 })
        #expect(h.voice.spoken == [C.troubleLine, C.openingFallback])
        #expect(h.coordinator.connectionProblem == .notConfigured)
        #expect(await h.transport.requests.isEmpty)
    }

    @Test func 返事が遅いと定型句でつなぎ一定時間で諦めて聞き直す() async throws {
        let h = try SessionHarness()
        await startSession(h)
        await h.transport.enqueue(.lines, "/v1/claude", [.hang])

        await h.say("ねえ先生、これわかんない")
        #expect(await eventually { h.coordinator.conversationState == .thinking })
        let before = h.voice.spoken.count
        await advance(h, by: h.coordinator.settings.patience.replyFiller)
        #expect(await eventually { h.voice.spoken.last == C.replyFiller })

        await advance(h, by: h.coordinator.settings.patience.replyGiveUp)
        #expect(await eventually { h.voice.spoken.suffix(2) == [C.troubleLine, C.replyFallback] })
        #expect(h.voice.spoken.count == before + 3)
        #expect(await eventually { h.coordinator.conversationState == .idle })
        #expect(h.coordinator.connectionProblem == .timeout)
        // 子どもの発話と決まり文句は履歴に残り、次の返事は作れる
        #expect(await h.lastAssistantText() == C.troubleLine + C.replyFallback)
        await h.enqueueReply(["うん、どこ？"])
        await h.say("ねえ先生")
        #expect(await eventually { h.voice.spoken.last == "うん、どこ？" })
    }

    @Test func 返事が途中で止まったら話せたところまで話して聞き直す() async throws {
        let h = try SessionHarness()
        await startSession(h)
        // 1 文目と、文の途中までが届いて止まる
        await h.transport.enqueue(.lines, "/v1/claude", [.partial(SSEFixture.partialTextStream(["まず問題を読もう。", "何を"]))])

        await h.say("ねえ先生、これわかんない")
        #expect(await eventually { h.voice.spoken.last == "まず問題を読もう。" })
        await advance(h, by: h.coordinator.settings.patience.replyGiveUp)
        #expect(await eventually { h.voice.spoken.suffix(3) == ["まず問題を読もう。", C.troubleLine, C.replyFallback] })
        #expect(await eventually { h.coordinator.conversationState == .idle })
        // 話していない「何を」は履歴に残さない
        #expect(await h.lastAssistantText() == "まず問題を読もう。" + C.troubleLine + C.replyFallback)
    }

    @Test func つないでいる間に割り込まれたら返事を捨てて聞く() async throws {
        let h = try SessionHarness()
        await startSession(h)
        h.voice.holdsPlayback = true
        await h.transport.enqueue(.lines, "/v1/claude", [.hang])

        await h.say("ねえ先生、これわかんない")
        await advance(h, by: h.coordinator.settings.patience.replyFiller)
        #expect(await eventually { h.voice.spoken.last == C.replyFiller })
        let count = h.voice.spoken.count
        h.input.send(.voiceStarted)
        #expect(await eventually { h.coordinator.conversationState == .listening })
        h.voice.holdsPlayback = false
        // 諦める時間を過ぎても、捨てた返事の決まり文句は話さない
        await advance(h, by: h.coordinator.settings.patience.replyGiveUp, step: .seconds(1))
        try await Task.sleep(for: .milliseconds(50))
        #expect(!h.voice.spoken.dropFirst(count).contains(C.troubleLine))
        #expect(h.coordinator.connectionProblem == nil)
    }

    @Test func 写真の分析が返ってこなくても撮影中で固まらない() async throws {
        let camera = MockCamera()
        let h = try SessionHarness(camera: camera)
        await startSession(h)
        await h.transport.enqueue(.data, "/v1/claude", [.hang])

        let capture = Task { await h.coordinator.captureFromButton() }
        // 写真を送って、返事を待っているところ
        #expect(await eventually { await h.transport.count(.data, "/v1/claude") == 1 })
        #expect(camera.captureCount == 1)
        #expect(h.coordinator.isCapturing)
        try await Task.sleep(for: .milliseconds(20))
        await advance(h, by: h.coordinator.settings.patience.analysisGiveUp, step: .seconds(2))
        await capture.value
        #expect(!h.coordinator.isCapturing)
        #expect(h.voice.spoken.suffix(2) == [C.troubleLine, C.analysisOfflineLine])
        #expect(h.coordinator.connectionProblem == .timeout)
    }

    @Test func カメラが拒否されていたら声で読んでもらう() async throws {
        let camera = MockCamera()
        camera.prepareError = CameraError.unauthorized
        let h = try SessionHarness(camera: camera)
        await startSession(h)

        await h.coordinator.captureFromButton()
        #expect(h.voice.spoken.last == C.cameraDeniedLine)
        #expect(!h.coordinator.isCapturing)
        #expect(h.coordinator.connectionProblem == nil)
    }

    @Test func ふり返りが返ってこなくても保存して決まり文句で終わる() async throws {
        var settings = StudySessionCoordinator.Settings()
        settings.patience.reflectionGiveUp = .milliseconds(100)
        let h = try SessionHarness(settings: settings)
        await startSession(h)
        await h.transport.enqueue(.data, "/v1/claude", [.hang])

        await h.coordinator.end()
        #expect(h.coordinator.phase == .idle)
        #expect(try await h.store.recentSessions(limit: 5).count == 1)
        #expect(h.voice.spoken.last == SessionReflector.fallback(for: .init(startedAt: .now, endedAt: .now, focusMinutes: 0, transcript: [], problems: [])).spokenClosing)
    }
}

@MainActor
struct TeacherVoiceCooldownTests {
    @Test func Workerの声が失敗したらしばらく端末の声だけで話す() async {
        let player = MockAudioPlayer()
        let eleven = MockTTSProvider(identifier: "eleven", behavior: .fail(WorkerError.http(status: 502, body: "")))
        let system = MockTTSProvider(identifier: "system")
        let voice = TeacherVoice(primary: eleven, fallback: system, player: player, lipSync: LipSyncPlayer())

        for (index, text) in ["ちょっと", "まってね"].enumerated() {
            let task = Task { await voice.say(text) }
            await player.waitUntilPlaying(count: index + 1)
            player.finish()
            _ = await task.value
        }
        // 2 文目は Worker を待たない
        #expect(eleven.requests == ["ちょっと"])
        #expect(system.requests == ["ちょっと", "まってね"])
    }
}
