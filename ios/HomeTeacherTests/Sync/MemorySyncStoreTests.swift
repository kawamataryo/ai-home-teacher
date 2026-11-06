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
}
