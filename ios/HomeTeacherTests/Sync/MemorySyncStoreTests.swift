import Foundation
import Testing
@testable import HomeTeacher

/// #25 の SwiftDataMemoryStore（メモリ上）を MemorySyncStore 越しに同期する。
struct MemorySyncStoreTests {
    private let start = SyncFixture.date("2026-11-03T07:00:00.000Z")

    private func record(_ id: String, summary: String = "割合の文章題") -> StudySessionRecord {
        StudySessionRecord(
            id: id, startedAt: start, endedAt: start.addingTimeInterval(30 * 60), focusMinutes: 25,
            summary: summary, teacherNote: "自力で解けました！", flags: ["けんかしたと話していた"],
            problems: [ProblemRecord(kind: .reading, summary: "グラフの読み取り", solvedBySelf: false,
                                     hintLevelReached: 2, createdAt: start.addingTimeInterval(60))]
        )
    }

    private func service(_ transport: MockTransport, _ store: MemorySyncStore) -> SyncService {
        let client = WorkerClient(baseURL: URL(string: "https://example.workers.dev")!, familyToken: "t", transport: transport)
        return SyncService(client: client, store: store, sleep: { _ in }, now: { SyncFixture.date("2026-11-03T08:00:00.000Z") })
    }

    @Test func 保存したセッションを送って送信済みにする() async throws {
        let base = try SwiftDataMemoryStore.inMemory()
        let store = MemorySyncStore(base: base, stateStorage: InMemorySyncStateStorage())
        try await store.saveSession(record("s1"))
        let sent = SessionDTO(record: record("s1"))
        let transport = MockTransport(responses: [SyncFixture.postOK(sent)] + SyncFixture.emptyPull)

        let report = await service(transport, store).syncNow(reason: .sessionEnded)

        #expect(report.pushedSessionIDs == ["s1"])
        #expect(try await base.unsyncedSessions().isEmpty)
        #expect(try await base.latestSession()?.syncedAt == SyncFixture.date("2026-11-03T08:00:00.000Z"))
        let body = try #require(await transport.requests.first?.httpBody)
        #expect(try SyncCoding.decoder.decode(SessionDTO.self, from: body) == sent)
        #expect(sent.problems.first?.kind == .reading)
        #expect(sent.flags == ["けんかしたと話していた"])
    }

    @Test func ふり返りで書き換えた記憶を送ってからサーバーの内容に揃える() async throws {
        let base = try SwiftDataMemoryStore.inMemory()
        let storage = InMemorySyncStateStorage()
        let store = MemorySyncStore(base: base, stateStorage: storage)
        var updates = MemoryUpdates()
        updates[.likes] = .init(add: ["サッカー"])
        try await store.applyMemoryUpdates(updates, now: start)
        #expect(await store.pendingMemoryCategories() == [.likes])
        // アプリを再起動しても「まだ送れていない」は残る
        #expect(storage.load().dirtyMemoryCategories == [.likes])

        let transport = MockTransport(responses: [
            SyncFixture.memories([(.likes, "サッカー")]),
            SyncFixture.memories([(.likes, "サッカー"), (.weakPoints, "割合")]),
            SyncFixture.sessionsPage([], serverTime: "2026-11-03T09:00:00.000Z"),
            SyncFixture.noMessages,
        ])
        let report = await service(transport, store).syncNow(reason: .sessionEnded)

        #expect(report.pushedMemoryCategories == [.likes])
        let put = try #require(await transport.requests.first?.httpBody)
        #expect(String(decoding: put, as: UTF8.self) == #"{"category":"likes","items":[{"content":"サッカー"}]}"#)
        #expect(try await base.memories(category: .weakPoints).map(\.content) == ["割合"])
        #expect(await store.pendingMemoryCategories().isEmpty)

        let reopened = MemorySyncStore(base: base, stateStorage: storage)
        #expect(await reopened.lastPullAt == SyncFixture.date("2026-11-03T09:00:00.000Z"))
        #expect(await reopened.pendingMemoryCategories().isEmpty)
    }

    @Test func 取ってきたセッションは送信済みで保存しまだ送れていないものは上書きしない() async throws {
        let base = try SwiftDataMemoryStore.inMemory()
        let store = MemorySyncStore(base: base, stateStorage: InMemorySyncStateStorage())
        try await store.saveSession(record("local", summary: "端末の要約"))

        var remoteLocal = SessionDTO(record: record("local", summary: "サーバーの古い要約"))
        remoteLocal.updatedAt = SyncFixture.date("2026-11-02T00:00:00.000Z")
        let other = SessionDTO(record: record("other", summary: "別の端末"))
        try await store.upsertRemoteSessions([remoteLocal, other].map {
            var s = $0
            s.updatedAt = SyncFixture.date("2026-11-02T00:00:00.000Z")
            return s
        })

        let all = try await base.recentSessions(limit: 10)
        #expect(all.first { $0.id == "local" }?.summary == "端末の要約")
        #expect(all.first { $0.id == "other" }?.syncedAt == SyncFixture.date("2026-11-02T00:00:00.000Z"))
        #expect(try await store.pendingSessions().map(\.id) == ["local"])
    }

    // MARK: - 親の伝言（#159）

    private func message(_ id: String, at seconds: Double) -> ParentMessage {
        ParentMessage(id: id, senderLabel: "お母さん", body: "がんばってね", createdAt: start.addingTimeInterval(seconds))
    }

    @Test func 伝言は古い順に出し再起動しても残る() async throws {
        let base = try SwiftDataMemoryStore.inMemory()
        let storage = InMemorySyncStateStorage()
        let store = MemorySyncStore(base: base, stateStorage: storage)
        await store.replaceParentMessages([message("new", at: 60), message("old", at: 0)])
        #expect(await store.nextParentMessage()?.id == "old")

        let reopened = MemorySyncStore(base: base, stateStorage: storage)
        #expect(await reopened.nextParentMessage()?.id == "old")
    }

    @Test func 伝えた伝言はサーバーに伝わる前に取ってきても戻らない() async throws {
        let store = MemorySyncStore(base: try SwiftDataMemoryStore.inMemory(), stateStorage: InMemorySyncStateStorage())
        await store.replaceParentMessages([message("m1", at: 0), message("m2", at: 60)])
        await store.markParentMessageTold(id: "m1", at: start)
        #expect(await store.nextParentMessage()?.id == "m2")

        await store.replaceParentMessages([message("m1", at: 0), message("m2", at: 60)])
        #expect(await store.nextParentMessage()?.id == "m2")
        #expect(await store.toldParentMessages() == ["m1": start])

        await store.forgetParentMessage(id: "m1")
        #expect(await store.toldParentMessages().isEmpty)
    }

    @Test func 古い版が保存した同期の状態も読める() throws {
        let json = #"{"lastPullAt":800000000,"dirtyMemoryCategories":["likes"]}"#
        let state = try JSONDecoder().decode(SyncState.self, from: Data(json.utf8))
        #expect(state.dirtyMemoryCategories == [.likes])
        #expect(state.lastPullAt != nil)
        #expect(state.parentMessages.isEmpty)
        #expect(state.toldParentMessages.isEmpty)
    }

    // MARK: - 親が消した記憶（#160）

    /// 記憶の同期 API だけを持つ小さなサーバー。Worker と同じく、based_on 以降に消されたものを PUT から取り除く
    private actor FakeMemoryServer: HTTPTransport {
        var rows: [String] = []
        var deletions: [(content: String, at: Date)] = []
        var clock = Date(timeIntervalSince1970: 1_793_000_000)
        private(set) var puts: [MemoryPutRequest] = []
        private var beforeGetMemory: (@Sendable () async -> Void)?

        func setBeforeGetMemory(_ hook: @escaping @Sendable () async -> Void) { beforeGetMemory = hook }

        func seed(_ contents: [String]) { rows = contents }

        func parentDeletes(_ content: String) {
            clock.addTimeInterval(1)
            rows.removeAll { $0 == content }
            deletions.append((content, clock))
        }

        private func listBody() -> Data {
            clock.addTimeInterval(1)
            let items = rows.enumerated().map { index, content in
                #"{"id":"m\#(index)","child_id":"default","category":"likes","content":"\#(content)","updated_at":"2026-11-03T00:00:00.000Z"}"#
            }
            return Data((#"{"memories":["# + items.joined(separator: ",") + #"],"server_time":"\#(SyncCoding.formatDate(clock))"}"#).utf8)
        }

        func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let path = request.url?.path() ?? ""
            let body: Data
            switch (request.httpMethod, path) {
            case ("PUT", "/v1/memory"):
                let put = try SyncCoding.decoder.decode(MemoryPutRequest.self, from: request.httpBody ?? Data())
                puts.append(put)
                let base = put.basedOn
                rows = put.items.map(\.content).filter { content in
                    !deletions.contains { $0.content == content && (base == nil || $0.at >= base!) }
                }
                body = listBody()
            case ("GET", "/v1/memory"):
                if let hook = beforeGetMemory {
                    beforeGetMemory = nil
                    await hook()
                }
                body = listBody()
            case ("GET", "/v1/sessions"):
                body = Data(#"{"sessions":[],"server_time":"2026-11-03T09:00:00.000Z"}"#.utf8)
            default:
                body = Data(#"{"messages":[]}"#.utf8)
            }
            return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        func lines(for request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse) {
            throw URLError(.badURL)
        }
    }

    @Test func 未送信の変更があっても親が消した記憶は復活せず次のプロンプトに入らない() async throws {
        let server = FakeMemoryServer()
        await server.seed(["サッカー", "猫のミケ"])
        let client = WorkerClient(baseURL: URL(string: "https://example.workers.dev")!, familyToken: "t", transport: server)
        let base = try SwiftDataMemoryStore.inMemory()
        let store = MemorySyncStore(base: base, stateStorage: InMemorySyncStateStorage())
        let sync = SyncService(client: client, store: store, sleep: { _ in })

        // 1. 同期して、端末に「猫のミケ」がある
        #expect(await sync.syncNow(reason: .appLaunch).outcome == .completed)
        #expect(try await base.memories(category: .likes).map(\.content).contains("猫のミケ"))
        let basedOn = try #require(await store.memoryBase(category: .likes))

        // 2. 親が消す。その間に端末はふり返りで同じカテゴリを書き換える（まだ送れていない）
        await server.parentDeletes("猫のミケ")
        var updates = MemoryUpdates()
        updates[.likes] = .init(add: ["マイクラ"])
        try await store.applyMemoryUpdates(updates, now: start)
        #expect(await store.pendingMemoryCategories() == [.likes])
        #expect(try await base.memories(category: .likes).map(\.content).contains("猫のミケ"))

        // 3. 同期すると、新しく覚えたことは残り、消した記憶は戻らない
        let report = await sync.syncNow(reason: .sessionEnded)
        #expect(report.outcome == .completed)
        #expect(report.pushedMemoryCategories == [.likes])
        #expect(await server.puts.last?.basedOn == basedOn)
        #expect(await server.rows.sorted() == ["サッカー", "マイクラ"].sorted())
        let local = try await base.memories(category: .likes).map(\.content)
        #expect(Set(local) == ["サッカー", "マイクラ"])
        #expect(await store.pendingMemoryCategories().isEmpty)

        // 4. 次のセッションのプロンプトに入らない
        let text = OpeningPromptBuilder().previousSessionText(last: nil, memories: try await store.memories(), now: start)
        #expect(text?.contains("マイクラ") == true)
        #expect(text?.contains("ミケ") == false)
    }

    @Test func 未送信の変更がないカテゴリは取ってくるだけで消える() async throws {
        let server = FakeMemoryServer()
        await server.seed(["サッカー", "猫のミケ"])
        let client = WorkerClient(baseURL: URL(string: "https://example.workers.dev")!, familyToken: "t", transport: server)
        let base = try SwiftDataMemoryStore.inMemory()
        let store = MemorySyncStore(base: base, stateStorage: InMemorySyncStateStorage())
        let sync = SyncService(client: client, store: store, sleep: { _ in })
        _ = await sync.syncNow(reason: .appLaunch)

        await server.parentDeletes("猫のミケ")
        _ = await sync.syncNow(reason: .sessionStarting)
        #expect(try await base.memories(category: .likes).map(\.content) == ["サッカー"])
        #expect(await server.puts.isEmpty)
    }

    @Test func 消えたことを知ったあとにまた話した記憶は覚え直せる() async throws {
        let server = FakeMemoryServer()
        await server.seed(["猫のミケ"])
        let client = WorkerClient(baseURL: URL(string: "https://example.workers.dev")!, familyToken: "t", transport: server)
        let base = try SwiftDataMemoryStore.inMemory()
        let store = MemorySyncStore(base: base, stateStorage: InMemorySyncStateStorage())
        let sync = SyncService(client: client, store: store, sleep: { _ in })
        _ = await sync.syncNow(reason: .appLaunch)
        await server.parentDeletes("猫のミケ")
        _ = await sync.syncNow(reason: .sessionStarting)

        var updates = MemoryUpdates()
        updates[.likes] = .init(add: ["猫のミケ"])
        try await store.applyMemoryUpdates(updates, now: start)
        _ = await sync.syncNow(reason: .sessionEnded)
        #expect(await server.rows == ["猫のミケ"])
    }

    @Test func 同期の途中で書き換えたカテゴリは基準の時刻を進めない() async throws {
        let server = FakeMemoryServer()
        await server.seed(["猫のミケ"])
        let client = WorkerClient(baseURL: URL(string: "https://example.workers.dev")!, familyToken: "t", transport: server)
        let base = try SwiftDataMemoryStore.inMemory()
        let store = MemorySyncStore(base: base, stateStorage: InMemorySyncStateStorage())
        let sync = SyncService(client: client, store: store, sleep: { _ in })
        _ = await sync.syncNow(reason: .appLaunch)
        let before = try #require(await store.memoryBase(category: .likes))

        // 取ってくる直前に端末が書き換える（ふり返りと同期が重なったとき）。古い内容のままなので基準を進めてはいけない
        let start = self.start
        await server.setBeforeGetMemory {
            var updates = MemoryUpdates()
            updates[.likes] = .init(add: ["マイクラ"])
            try? await store.applyMemoryUpdates(updates, now: start)
        }
        _ = await sync.syncNow(reason: .manual)
        #expect(await store.memoryBase(category: .likes) == before)
        #expect(await store.pendingMemoryCategories() == [.likes])
    }
}
