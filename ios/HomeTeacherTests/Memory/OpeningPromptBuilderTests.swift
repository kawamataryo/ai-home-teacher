import Foundation
import Testing
@testable import HomeTeacher

struct OpeningPromptBuilderTests {
    /// 日付の境目がずれないように、タイムゾーンを固定する。
    private var builder: OpeningPromptBuilder {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return OpeningPromptBuilder(calendar: calendar)
    }

    /// 2026-11-03 16:00 JST
    private let lastStart = Date(timeIntervalSince1970: 1_793_689_200)
    /// 翌日 2026-11-04 00:30 JST（日付が変わった直後でも「昨日」）
    private var nextDay: Date { lastStart.addingTimeInterval(8.5 * 3600) }

    private var lastSession: StudySessionRecord {
        StudySessionRecord(
            id: "S-1", startedAt: lastStart, endedAt: lastStart.addingTimeInterval(2400), focusMinutes: 35,
            summary: "割合の文章題を3問やった。もとにする量を自分で見つけられた。",
            teacherNote: "割合の問題を自力で解けました！",
            flags: ["学校で友だちとけんかしたと話していた"],
            problems: [ProblemRecord(kind: .thinking, summary: "割合：もとにする量を求める", solvedBySelf: true, createdAt: lastStart)]
        )
    }

    private let memories = [
        MemoryRecord(category: .likes, content: "サッカー", updatedAt: Date(timeIntervalSince1970: 1_793_000_000)),
        MemoryRecord(category: .likes, content: "猫のミケ", updatedAt: Date(timeIntervalSince1970: 1_793_100_000)),
        MemoryRecord(category: .weakPoints, content: "グラフの読み取り", updatedAt: Date(timeIntervalSince1970: 1_793_000_000)),
    ]

    @Test func 前回の要約と記憶を入れて要確認は入れない() throws {
        let text = try #require(builder.previousSessionText(last: lastSession, memories: memories, now: nextDay))
        #expect(text.contains("## 前回の勉強（昨日）"))
        #expect(text.contains("要約：割合の文章題を3問やった。"))
        #expect(text.contains("取り組んだ問題：割合：もとにする量を求める（自力で解けた）"))
        #expect(text.contains("先生からのひとこと：割合の問題を自力で解けました！"))
        #expect(text.contains("- 好きなこと：猫のミケ、サッカー"))
        #expect(text.contains("- 苦手な単元：グラフの読み取り"))
        #expect(!text.contains("最近の出来事"))
        #expect(!text.contains("けんか"))
    }

    @Test func 何もなければnil() {
        #expect(builder.previousSessionText(last: nil, memories: [], now: nextDay) == nil)
        let onlyMemories = builder.previousSessionText(last: nil, memories: memories, now: nextDay)
        #expect(onlyMemories?.hasPrefix("## 覚えていること") == true)
    }

    @Test(arguments: [
        (0.0, "今日"), (8.5, "昨日"), (24.0, "昨日"), (40.0, "おととい"), (24.0 * 5, "5日前"),
    ])
    func 前回がいつかを言葉にする(hours: Double, expected: String) {
        #expect(builder.relativeDayText(lastStart, now: lastStart.addingTimeInterval(hours * 3600)) == expected)
    }

    @Test func 会話用のプロンプトに前回のことを足して開始の指示を入れる() async throws {
        let store = try SwiftDataMemoryStore.inMemory()
        try await store.saveSession(lastSession)
        try await store.replaceMemories(category: .likes, with: memories.filter { $0.category == .likes })

        let prompt = try await builder.conversationSystemPrompt(store: store, now: nextDay)
        let parts = prompt.components(separatedBy: PromptLibrary.separator)
        let library = PromptLibrary()
        // 既存の4つはそのまま。その後ろに前回のこと
        #expect(Array(parts.prefix(4)) == [
            try library.load(.teacher), try library.load(.hintLadder), try library.load(.safety),
            try library.load(.smallTalk, variables: ["session_mode": "勉強中"]),
        ])
        #expect(parts.count == 5)
        let opening = parts[4]
        #expect(opening.hasPrefix("# 前回のこと"))
        #expect(opening.contains("〈いつ〉の割合の続きやる？"))
        #expect(opening.contains("## 前回の勉強（昨日）"))
        #expect(opening.contains("割合の文章題を3問やった"))
        #expect(opening.contains("猫のミケ"))
        #expect(!opening.contains("けんか"))
        #expect(!prompt.contains("{{"))
    }

    @Test func 初めてのときは前回のことを足さない() async throws {
        let store = try SwiftDataMemoryStore.inMemory()
        let prompt = try await builder.conversationSystemPrompt(store: store, now: nextDay)
        #expect(prompt == (try PromptLibrary().conversationSystemPrompt()))
        #expect(!prompt.contains("# 前回のこと"))
    }

    @Test func 休憩中や先生のメモで作り直しても前回のことは残る() async throws {
        let store = try SwiftDataMemoryStore.inMemory()
        try await store.saveSession(lastSession)
        let prompt = try await builder.conversationSystemPrompt(store: store, mode: .rest, teacherNote: "正答は 40", now: nextDay)
        let parts = prompt.components(separatedBy: PromptLibrary.separator)
        #expect(parts.count == 6)
        #expect(parts[3].contains("**休憩中**"))
        #expect(parts[4].hasPrefix("# 前回のこと"))
        #expect(parts[4].contains("割合の文章題を3問やった"))
        #expect(parts[5].hasPrefix("# 先生のメモ"))
    }

    @Test func 先生のメモは前回のことより後ろに足す() throws {
        let prompt = try PromptLibrary().conversationSystemPrompt(teacherNote: "正答は 40", previousSession: "## 前回の勉強（昨日）")
        let parts = prompt.components(separatedBy: PromptLibrary.separator)
        #expect(parts.count == 6)
        #expect(parts[4].hasPrefix("# 前回のこと"))
        #expect(parts[5].hasPrefix("# 先生のメモ"))
    }
}
