import Foundation
import Testing
@testable import HomeTeacher

/// 待った時間を記録するだけで、実際には待たない。
actor SleepRecorder {
    private(set) var delays: [Duration] = []
    func record(_ delay: Duration) { delays.append(delay) }
}

/// つながったことを好きなときに知らせるモック。
final class MockConnectivity: ConnectivityMonitoring, Sendable {
    let stream: AsyncStream<Void>
    let continuation: AsyncStream<Void>.Continuation

    init() {
        (stream, continuation) = AsyncStream<Void>.makeStream()
    }

    func connectivityRestored() -> AsyncStream<Void> { stream }
    func restore() { continuation.yield() }
}

/// サーバーの応答を組み立てる。
enum SyncFixture {
    static func date(_ text: String) -> Date { SyncDTOTests.utc(text) }

    static func session(_ id: String, startedAt: String = "2026-11-03T07:00:00.000Z", updatedAt: Date? = nil) -> SessionDTO {
        let start = date(startedAt)
        return SessionDTO(
            id: id, startedAt: start, endedAt: start.addingTimeInterval(30 * 60), focusMinutes: 25,
            summary: "割合の文章題", teacherNote: "自力で解けました！", flags: [],
            problems: [ProblemDTO(kind: .thinking, summary: "割合", solvedBySelf: true, hintLevelReached: 1,
                                  createdAt: start.addingTimeInterval(60))],
            updatedAt: updatedAt
        )
    }

    /// サーバーが返す形の session（updated_at と problems[].id 付き）。
    static func sessionJSON(_ session: SessionDTO, updatedAt: Date) -> [String: Any] {
        [
            "id": session.id, "child_id": "default",
            "started_at": SyncCoding.formatDate(session.startedAt), "ended_at": SyncCoding.formatDate(session.endedAt),
            "focus_minutes": session.focusMinutes, "summary": session.summary, "teacher_note": session.teacherNote,
            "flags": session.flags, "updated_at": SyncCoding.formatDate(updatedAt),
            "problems": session.problems.enumerated().map { index, p in
                [
                    "id": "p\(index)", "kind": p.kind.rawValue, "summary": p.summary, "solved_by_self": p.solvedBySelf,
                    "hint_level_reached": p.hintLevelReached,
                    "created_at": SyncCoding.formatDate(p.createdAt ?? session.startedAt),
                ] as [String: Any]
            },
        ]
    }

    static func postOK(_ session: SessionDTO) -> MockTransport.Response {
        .init(body: SSEFixture.json(["session": sessionJSON(session, updatedAt: date("2026-11-03T08:00:00.000Z"))]))
    }

    static func memories(_ items: [(MemoryCategory, String)]) -> MockTransport.Response {
        .init(body: SSEFixture.json(["memories": items.enumerated().map { index, item in
            ["id": "m\(index)", "child_id": "default", "category": item.0.rawValue, "content": item.1,
             "updated_at": "2026-11-03T08:00:00.000Z"]
        }]))
    }

    static func sessionsPage(_ sessions: [(SessionDTO, Date)], serverTime: String = "2026-11-03T09:00:00.000Z") -> MockTransport.Response {
        .init(body: SSEFixture.json([
            "sessions": sessions.map { sessionJSON($0.0, updatedAt: $0.1) },
            "server_time": serverTime,
        ]))
    }

    static let emptyPull: [MockTransport.Response] = [memories([]), sessionsPage([])]
}

struct SyncServiceTests {
    private func service(_ transport: MockTransport, _ store: InMemorySyncStore, sleeps: SleepRecorder = SleepRecorder()) -> SyncService {
        let client = WorkerClient(baseURL: URL(string: "https://example.workers.dev")!, familyToken: "token-123", transport: transport)
        return SyncService(
            client: client, store: store,
            sleep: { await sleeps.record($0) },
            now: { SyncFixture.date("2026-11-03T08:00:00.000Z") }
        )
    }

    private func paths(_ transport: MockTransport) async -> [String] {
        await transport.requests.map { "\($0.httpMethod ?? "") \($0.url?.path() ?? "")" }
    }

    private func query(_ request: URLRequest) -> [String: String] {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    /// 条件がそろうまで少し待つ（監視のタスクが動くのを待つ）。
    private func eventually(_ condition: @Sendable () async -> Bool) async -> Bool {
        for _ in 0..<300 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    // MARK: - 送る

    @Test func pendingのセッションをPOSTしてから取ってくる() async throws {
        let session = SyncFixture.session("6F1C2E1A-0000-4000-8000-000000000001")
        let store = InMemorySyncStore(sessions: [session])
        let transport = MockTransport(responses: [SyncFixture.postOK(session)] + SyncFixture.emptyPull)

        let report = await service(transport, store).syncNow(reason: .sessionEnded)

        #expect(report.outcome == .completed)
        #expect(report.pushedSessionIDs == [session.id])
        #expect(await store.pendingSessions().isEmpty)
        #expect(await paths(transport) == ["POST /v1/sessions", "GET /v1/memory", "GET /v1/sessions"])

        // 本文はサーバーの入力の形（updated_at と problems[].id は入れない）
        let request = try #require(await transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token-123")
        let httpBody = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: httpBody) as? [String: Any])
        #expect(Set(body.keys) == ["id", "started_at", "ended_at", "focus_minutes", "summary", "teacher_note", "flags", "problems"])
        #expect(body["id"] as? String == session.id)
        #expect(body["started_at"] as? String == "2026-11-03T07:00:00.000Z")
        #expect(body["ended_at"] as? String == "2026-11-03T07:30:00.000Z")
        let problem = try #require((body["problems"] as? [[String: Any]])?.first)
        #expect(Set(problem.keys) == ["kind", "summary", "solved_by_self", "hint_level_reached", "created_at"])
        #expect(problem["kind"] as? String == "thinking")
    }

    @Test func 送れたセッションは次の同期で送り直さない() async throws {
        let session = SyncFixture.session("s1")
        let store = InMemorySyncStore(sessions: [session])
        let transport = MockTransport(responses: [SyncFixture.postOK(session)] + SyncFixture.emptyPull + SyncFixture.emptyPull)
        let sync = service(transport, store)

        await sync.syncNow(reason: .sessionEnded)
        let second = await sync.syncNow(reason: .appLaunch)

        #expect(second.pushedSessionIDs.isEmpty)
        #expect(await paths(transport).filter { $0 == "POST /v1/sessions" }.count == 1)
    }

    @Test func 同時に呼ばれても同じセッションを二重に送らない() async throws {
        let session = SyncFixture.session("s1")
        let store = InMemorySyncStore(sessions: [session])
        // 2回目の同期がまわっても足りるだけの応答
        let transport = MockTransport(responses: [SyncFixture.postOK(session)] + SyncFixture.emptyPull + SyncFixture.emptyPull)
        let sync = service(transport, store)

        async let a = sync.syncNow(reason: .appLaunch)
        async let b = sync.syncNow(reason: .connectivityRestored)
        let reports = await [a, b]

        #expect(reports.allSatisfy { $0.outcome == .completed })
        #expect(await paths(transport).filter { $0 == "POST /v1/sessions" }.count == 1)
        #expect(await store.pendingSessions().isEmpty)
    }

    @Test func 送り直すときも同じidで送る() async throws {
        // サーバーは id で上書きするので、同じ id で何度送っても重複しない
        let session = SyncFixture.session("s1")
        let store = InMemorySyncStore(sessions: [session])
        let transport = MockTransport(responses: [
            .init(status: 503, body: #"{"error":"unavailable"}"#), SyncFixture.postOK(session),
        ] + SyncFixture.emptyPull)

        await service(transport, store).syncNow(reason: .sessionEnded)

        let bodies = await transport.requests.filter { $0.httpMethod == "POST" }.compactMap(\.httpBody)
        #expect(bodies.count == 2)
        #expect(bodies[0] == bodies[1])
    }

    // MARK: - やり直し

    @Test func クライアントエラー4xxはやり直さずpendingのまま次へ進む() async throws {
        let bad = SyncFixture.session("bad", startedAt: "2026-11-03T06:00:00.000Z")
        let good = SyncFixture.session("good")
        let store = InMemorySyncStore(sessions: [bad, good])
        let sleeps = SleepRecorder()
        let transport = MockTransport(responses: [
            .init(status: 400, body: #"{"error":"invalid request"}"#), SyncFixture.postOK(good),
        ] + SyncFixture.emptyPull)

        let report = await service(transport, store, sleeps: sleeps).syncNow(reason: .sessionEnded)

        #expect(report.outcome == .completed)
        #expect(report.rejectedSessionIDs == ["bad"])
        #expect(report.pushedSessionIDs == ["good"])
        #expect(await store.pendingSessions().map(\.id) == ["bad"])
        #expect(await paths(transport) == ["POST /v1/sessions", "POST /v1/sessions", "GET /v1/memory", "GET /v1/sessions"])
        #expect(await sleeps.delays.isEmpty)
    }

    @Test func サーバーエラー5xxは指数バックオフでやり直す() async throws {
        let session = SyncFixture.session("s1")
        let store = InMemorySyncStore(sessions: [session])
        let sleeps = SleepRecorder()
        let transport = MockTransport(responses: [
            .init(status: 500, body: "{}"), .init(status: 502, body: "{}"), SyncFixture.postOK(session),
        ] + SyncFixture.emptyPull)

        let report = await service(transport, store, sleeps: sleeps).syncNow(reason: .sessionEnded)

        #expect(report.outcome == .completed)
        #expect(report.pushedSessionIDs == ["s1"])
        #expect(await paths(transport).filter { $0 == "POST /v1/sessions" }.count == 3)
        #expect(await sleeps.delays == [.seconds(1), .seconds(2)])
    }

    @Test func サーバーエラー5xxが続いたら諦めてpendingのまま残す() async throws {
        let store = InMemorySyncStore(sessions: [SyncFixture.session("s1")])
        let sleeps = SleepRecorder()
        let transport = MockTransport(responses: Array(repeating: .init(status: 500, body: "{}"), count: 4))

        let report = await service(transport, store, sleeps: sleeps).syncNow(reason: .sessionEnded)

        guard case .failed = report.outcome else { Issue.record("failed になるはず: \(report.outcome)"); return }
        #expect(await transport.requests.count == RetryPolicy.default.maxAttempts)
        #expect(await sleeps.delays == [.seconds(1), .seconds(2), .seconds(4)])
        #expect(await store.pendingSessions().map(\.id) == ["s1"])
    }

    @Test func バックオフの待ち時間は上限で止まる() {
        let policy = RetryPolicy(maxAttempts: 10, baseDelay: .seconds(1), multiplier: 2, maxDelay: .seconds(30))
        #expect((1...7).map(policy.delay(afterAttempt:)) == [1, 2, 4, 8, 16, 30, 30].map { Duration.seconds($0) })
        #expect(RetryPolicy.isRetryable(URLError(.notConnectedToInternet)))
        #expect(RetryPolicy.isRetryable(WorkerError.http(status: 503, body: "")))
        #expect(!RetryPolicy.isRetryable(WorkerError.http(status: 401, body: "")))
        #expect(!RetryPolicy.isRetryable(URLError(.badURL)))
    }

    // MARK: - オフライン

    @Test func オフラインならpendingのまま残しつながったら送る() async throws {
        let session = SyncFixture.session("s1")
        let store = InMemorySyncStore(sessions: [session])
        let sleeps = SleepRecorder()
        let transport = MockTransport(responses: Array(repeating: .failure(.notConnectedToInternet), count: 4))
        let sync = service(transport, store, sleeps: sleeps)
        let connectivity = MockConnectivity()
        await sync.startMonitoring(connectivity)

        let offline = await sync.syncNow(reason: .sessionEnded)
        #expect(offline.outcome == .offline)
        #expect(await store.pendingSessions().map(\.id) == ["s1"])
        #expect(await transport.requests.count == 4)

        // つながったら、言われなくても送る
        await transport.enqueue([SyncFixture.postOK(session)] + SyncFixture.emptyPull)
        connectivity.restore()
        #expect(await eventually { await store.pendingSessions().isEmpty })
        #expect(await eventually { await sync.lastReport?.outcome == .completed })
        #expect(await paths(transport).suffix(3) == ["POST /v1/sessions", "GET /v1/memory", "GET /v1/sessions"])
        await sync.stopMonitoring()
    }

    // MARK: - 記憶

    @Test func 記憶はサーバーの内容でカテゴリごとに入れ替える() async throws {
        let old = MemoryDTO(id: "old", childID: "default", category: .weakPoints, content: "古い苦手",
                            updatedAt: SyncFixture.date("2026-11-01T00:00:00.000Z"))
        let store = InMemorySyncStore(memories: [.weakPoints: [old]])
        let transport = MockTransport(responses: [
            SyncFixture.memories([(.likes, "サッカー"), (.likes, "猫のミケ"), (.events, "運動会")]),
            SyncFixture.sessionsPage([]),
        ])

        let report = await service(transport, store).syncNow(reason: .appLaunch)

        #expect(report.pulledMemoryCategories == MemoryCategory.allCases)
        #expect(await store.memories[.likes]?.map(\.content) == ["サッカー", "猫のミケ"])
        #expect(await store.memories[.events]?.map(\.content) == ["運動会"])
        // サーバーで空のカテゴリは空になる（サーバーが正）
        #expect(await store.memories[.weakPoints] == [])
    }

    @Test func 端末で書き換えた記憶はPUTしてから取ってくる() async throws {
        let store = InMemorySyncStore()
        await store.setLocalMemories(["割合", "分数"], category: .weakPoints)
        let transport = MockTransport(responses: [
            SyncFixture.memories([(.weakPoints, "割合"), (.weakPoints, "分数")]),
            SyncFixture.memories([(.likes, "サッカー"), (.weakPoints, "割合"), (.weakPoints, "分数")]),
            SyncFixture.sessionsPage([]),
        ])

        let report = await service(transport, store).syncNow(reason: .sessionEnded)

        #expect(report.pushedMemoryCategories == [.weakPoints])
        #expect(await paths(transport) == ["PUT /v1/memory", "GET /v1/memory", "GET /v1/sessions"])
        let put = try #require(await transport.requests.first?.httpBody)
        #expect(String(decoding: put, as: UTF8.self) == #"{"category":"weak_points","items":[{"content":"割合"},{"content":"分数"}]}"#)
        #expect(await store.pendingMemoryCategories().isEmpty)
        #expect(await store.memories[.weakPoints]?.map(\.content) == ["割合", "分数"])
        #expect(await store.memories[.likes]?.map(\.content) == ["サッカー"])
    }

    @Test func 送れなかった記憶の書き換えはサーバーの内容で消さない() async throws {
        let store = InMemorySyncStore()
        await store.setLocalMemories(["運動会"], category: .events)
        let transport = MockTransport(responses: [
            .init(status: 400, body: #"{"error":"invalid request"}"#),
            SyncFixture.memories([(.likes, "サッカー")]),
            SyncFixture.sessionsPage([]),
        ])

        let report = await service(transport, store).syncNow(reason: .sessionEnded)

        #expect(report.pulledMemoryCategories == [.likes, .weakPoints])
        #expect(await store.localMemories(category: .events) == [MemoryItemDTO(content: "運動会")])
        #expect(await store.pendingMemoryCategories() == [.events])
    }

    // MARK: - セッションを取ってくる

    @Test func 一度に200件ならページ送りしてlastPullAtを進める() async throws {
        let lastPull = SyncFixture.date("2026-11-01T00:00:00.000Z")
        let store = InMemorySyncStore(lastPullAt: lastPull)
        let base = SyncFixture.date("2026-11-02T00:00:00.000Z")
        let page1 = (0..<200).map { i in (SyncFixture.session("a\(i)"), base.addingTimeInterval(Double(i))) }
        // 境目（最後の updated_at）の1件は2ページ目にも入る
        let page2 = [page1[199]] + (0..<3).map { i in (SyncFixture.session("b\(i)"), base.addingTimeInterval(Double(300 + i))) }
        let transport = MockTransport(responses: [
            SyncFixture.memories([]),
            SyncFixture.sessionsPage(page1, serverTime: "2026-11-03T09:00:00.000Z"),
            SyncFixture.sessionsPage(page2, serverTime: "2026-11-03T09:00:01.000Z"),
        ])

        let report = await service(transport, store).syncNow(reason: .appLaunch)

        #expect(report.outcome == .completed)
        let gets = await transport.requests.filter { $0.url?.path() == "/v1/sessions" }
        #expect(gets.count == 2)
        #expect(query(gets[0]) == ["since": "2026-11-01T00:00:00.000Z", "order": "updated", "limit": "200"])
        #expect(query(gets[1])["since"] == SyncCoding.formatDate(page1[199].1))
        #expect(await store.sessions.count == 203)
        #expect(await store.lastPullAt == SyncFixture.date("2026-11-03T09:00:00.000Z"))
    }

    @Test func 初回はsinceなしで取ってくる() async throws {
        let store = InMemorySyncStore()
        let remote = SyncFixture.session("r1")
        let transport = MockTransport(responses: [
            SyncFixture.memories([]),
            SyncFixture.sessionsPage([(remote, SyncFixture.date("2026-11-03T08:00:00.000Z"))]),
        ])

        let report = await service(transport, store).syncNow(reason: .appLaunch)

        #expect(report.pulledSessionCount == 1)
        let get = try #require(await transport.requests.last)
        #expect(query(get)["since"] == nil)
        #expect(await store.pendingSessions().isEmpty)
        #expect(await store.sessions["r1"]?.updatedAt == SyncFixture.date("2026-11-03T08:00:00.000Z"))
    }

    @Test func 取ってきたセッションはまだ送れていない端末のセッションを上書きしない() async {
        let local = SyncFixture.session("s1")
        let store = InMemorySyncStore(sessions: [local])
        var remote = SyncFixture.session("s1")
        remote.summary = "サーバーの古い要約"
        await store.upsertRemoteSessions([remote])
        #expect(await store.sessions["s1"]?.summary == local.summary)
        #expect(await store.pendingSessions().map(\.id) == ["s1"])
    }
}
