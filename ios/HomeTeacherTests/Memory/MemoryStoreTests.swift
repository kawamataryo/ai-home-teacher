import Foundation
import Testing
@testable import HomeTeacher

/// テストごとに別のメモリ上のコンテナを作る（Swift Testing は並列に走る）。
struct MemoryStoreTests {
    private let base = Date(timeIntervalSince1970: 1_793_000_000.123)

    private func session(id: String = "s1", startedAt: Date, summary: String = "割合の文章題を3問やった") -> StudySessionRecord {
        StudySessionRecord(
            id: id, startedAt: startedAt, endedAt: startedAt.addingTimeInterval(40 * 60), focusMinutes: 35,
            summary: summary, teacherNote: "自力で解けました！", flags: ["けんかしたと話していた"],
            problems: [
                ProblemRecord(kind: .thinking, summary: "割合：もとにする量", solvedBySelf: true, hintLevelReached: 1,
                              createdAt: startedAt.addingTimeInterval(300)),
                ProblemRecord(kind: .reading, summary: "グラフの読み取り", solvedBySelf: false, hintLevelReached: 3,
                              createdAt: startedAt.addingTimeInterval(900)),
            ]
        )
    }

    @Test func セッションを問題ごと保存して読み戻せる() async throws {
        let store = try SwiftDataMemoryStore.inMemory()
        let record = session(startedAt: base)
        try await store.saveSession(record)

        let latest = try #require(try await store.latestSession())
        #expect(latest == record)
        #expect(latest.syncedAt == nil)
    }

    @Test func 同じidで保存し直すと上書きする() async throws {
        let store = try SwiftDataMemoryStore.inMemory()
        try await store.saveSession(session(startedAt: base, summary: "前"))
        try await store.saveSession(session(startedAt: base, summary: "後"))

        let all = try await store.recentSessions(limit: 10)
        #expect(all.count == 1)
        #expect(all.first?.summary == "後")
    }

    @Test func 新しい順に返し未同期だけを古い順に返す() async throws {
        let store = try SwiftDataMemoryStore.inMemory()
        try await store.saveSession(session(id: "old", startedAt: base))
        try await store.saveSession(session(id: "new", startedAt: base.addingTimeInterval(86_400)))
        try await store.saveSession(session(id: "mid", startedAt: base.addingTimeInterval(3_600)))

        #expect(try await store.recentSessions(limit: 2).map(\.id) == ["new", "mid"])
        #expect(try await store.latestSession()?.id == "new")
        #expect(try await store.unsyncedSessions().map(\.id) == ["old", "mid", "new"])

        let syncedAt = base.addingTimeInterval(100_000)
        try await store.markSynced(sessionID: "mid", at: syncedAt)
        #expect(try await store.unsyncedSessions().map(\.id) == ["old", "new"])
        #expect(try await store.recentSessions(limit: 3).first { $0.id == "mid" }?.syncedAt == syncedAt)
    }

    @Test func 保存するときに同期APIの上限に収める() async throws {
        let store = try SwiftDataMemoryStore.inMemory()
        var record = session(startedAt: base)
        record.summary = String(repeating: "あ", count: 5000)
        record.teacherNote = String(repeating: "い", count: 1200)
        record.flags = (0..<25).map { "メモ\($0)" } + ["  "]
        record.focusMinutes = 2000
        record.problems.append(ProblemRecord(kind: .writing, summary: "  ", solvedBySelf: true, createdAt: base))
        record.problems[0].hintLevelReached = 7
        try await store.saveSession(record)

        let saved = try #require(try await store.latestSession())
        #expect(saved.summary.count == 4000)
        #expect(saved.teacherNote.count == 1000)
        #expect(saved.flags.count == 20)
        #expect(saved.focusMinutes == 1440)
        #expect(saved.problems.count == 2)
        #expect(saved.problems[0].hintLevelReached == 4)
    }

    @Test func 記憶をカテゴリごとに入れ替えて新しい順に返す() async throws {
        let store = try SwiftDataMemoryStore.inMemory()
        try await store.replaceMemories(category: .likes, with: [
            MemoryRecord(category: .likes, content: "サッカー", updatedAt: base),
            MemoryRecord(category: .likes, content: "猫のミケ", updatedAt: base.addingTimeInterval(10)),
        ])
        try await store.replaceMemories(category: .weakPoints, with: [
            MemoryRecord(category: .weakPoints, content: "割合の文章題", updatedAt: base),
        ])

        #expect(try await store.memories(category: .likes).map(\.content) == ["猫のミケ", "サッカー"])
        #expect(try await store.memories().map(\.category) == [.likes, .likes, .weakPoints])

        try await store.replaceMemories(category: .likes, with: [])
        #expect(try await store.memories().map(\.content) == ["割合の文章題"])
    }

    @Test func ふり返りの記憶の更新を足し込む() async throws {
        let store = try SwiftDataMemoryStore.inMemory()
        try await store.replaceMemories(category: .weakPoints, with: [
            MemoryRecord(category: .weakPoints, content: "割合の文章題", updatedAt: base),
            MemoryRecord(category: .weakPoints, content: "グラフの読み取り", updatedAt: base),
        ])
        var updates = MemoryUpdates()
        updates[.weakPoints] = .init(add: ["面積図"], remove: ["割合の文章題"])
        updates[.likes] = .init(add: ["サッカー", "サッカー "])
        let now = base.addingTimeInterval(86_400)
        try await store.applyMemoryUpdates(updates, now: now)

        #expect(try await store.memories(category: .weakPoints).map(\.content) == ["面積図", "グラフの読み取り"])
        let likes = try await store.memories(category: .likes)
        #expect(likes == [MemoryRecord(category: .likes, content: "サッカー", updatedAt: now)])
        #expect(try await store.memories(category: .events).isEmpty)
    }
}
