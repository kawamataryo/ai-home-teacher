import Foundation
import Testing
@testable import HomeTeacher

/// 本物の API は呼ばない（API キーなし）。MockTransport に Messages API の形の JSON を返させる。
struct SessionReflectorTests {
    private let start = Date(timeIntervalSince1970: 1_793_000_000)
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    private func makeReflector(_ transport: MockTransport) -> SessionReflector {
        let client = WorkerClient(baseURL: URL(string: "https://example.workers.dev")!, familyToken: "t", transport: transport)
        return SessionReflector(client: client, timeZone: tokyo)
    }

    private var input: SessionReflectionInput {
        var flags = SessionFlags()
        flags.record(ParentFlag(category: .bullying, reason: "学校で友だちとけんかしたと話していた", createdAt: start))
        return SessionReflectionInput(
            sessionID: "S-1",
            startedAt: start,
            endedAt: start.addingTimeInterval(40 * 60),
            focusMinutes: 35,
            transcript: [
                ChatMessage(role: .user, content: [.text("これ見て、割合わかんない")]),
                ChatMessage(role: .assistant, content: [
                    .text("どれどれ。何を聞かれてるかな？"),
                    .toolUse(id: "toolu_1", name: "flag_for_parent", input: .object([:])),
                ]),
                ChatMessage(role: .user, content: [.toolResult(toolUseID: "toolu_1", content: "記録しました。")]),
                ChatMessage(role: .user, content: [.text("もとにする量だ！")]),
            ],
            problems: [
                ProblemRecord(kind: .thinking, summary: "割合：もとにする量を求める", solvedBySelf: true, hintLevelReached: 1,
                              createdAt: start.addingTimeInterval(300)),
                ProblemRecord(kind: .reading, summary: "棒グラフの読み取り", solvedBySelf: false, hintLevelReached: 4,
                              createdAt: start.addingTimeInterval(1200)),
            ],
            flags: flags
        )
    }

    /// record_reflection を呼んだ Messages API のレスポンス。
    static func response(
        summary: String = "割合の文章題と棒グラフの読み取りに取り組んだ。割合はもとにする量を自分で見つけて解けた。",
        teacherNote: String = "割合の問題で、もとにする量を自分で見つけられました！",
        closing: String = "今日は2問やったね！割合の問題、もとにする量を自分で見つけられたのがすごかったよ。また明日もやろうね！",
        memory: [String: Any] = [
            "likes": ["add": ["サッカー"], "remove": [String]()],
            "events": ["add": [String](), "remove": [String]()],
            "weak_points": ["add": ["棒グラフの読み取り"], "remove": ["割合の文章題"]],
        ],
        stopReason: String = "tool_use"
    ) -> String {
        SSEFixture.json([
            "id": "msg_1", "type": "message", "role": "assistant", "model": "claude-sonnet-5-5",
            "stop_reason": stopReason,
            "content": [
                ["type": "text", "text": "記録します。"],
                ["type": "tool_use", "id": "toolu_9", "name": "record_reflection", "input": [
                    "summary": summary, "teacher_note": teacherNote, "spoken_closing": closing, "memory": memory,
                ]],
            ],
        ])
    }

    @Test func リクエストはSonnetでrecord_reflectionを必ず呼ばせる() async throws {
        let transport = MockTransport(body: Self.response())
        let reflector = makeReflector(transport)
        let memories = [MemoryRecord(category: .weakPoints, content: "割合の文章題", updatedAt: start)]
        _ = try await reflector.reflect(input, memories: memories)

        let request = try #require(await transport.requests.first)
        #expect(request.url?.path() == "/v1/claude")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer t")
        let body = try #require(await transport.requestBodies().first)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "claude-sonnet-5-5")
        #expect(json["stream"] as? Bool == false)
        #expect(json["max_tokens"] as? Int == 2000)
        let choice = try #require(json["tool_choice"] as? [String: Any])
        #expect(choice["type"] as? String == "tool")
        #expect(choice["name"] as? String == "record_reflection")

        let tools = try #require(json["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        #expect(tools[0]["name"] as? String == "record_reflection")
        #expect(tools[0]["strict"] as? Bool == true)
        let schema = try #require(tools[0]["input_schema"] as? [String: Any])
        #expect(schema["additionalProperties"] as? Bool == false)
        #expect(Set(schema["required"] as? [String] ?? []) == ["summary", "teacher_note", "spoken_closing", "memory"])
        let memory = try #require((schema["properties"] as? [String: Any])?["memory"] as? [String: Any])
        #expect(Set(memory["required"] as? [String] ?? []) == ["likes", "events", "weak_points"])

        // システムプロンプトは先生のキャラクター＋ふり返りの指示
        let system = try #require(json["system"] as? String)
        #expect(system.contains("ハル先生"))
        #expect(system.contains("spoken_closing"))

        // ユーザーの本文：数えた問題数・結果・いまの記憶・会話（ツールは除く）
        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages[0]["role"] as? String == "user")
        let text = try #require((messages[0]["content"] as? [[String: Any]])?.first?["text"] as? String)
        #expect(text.contains("取り組んだ問題（2問・自力で解けたのは1問）"))
        #expect(text.contains("割合：もとにする量を求める：自力で解けた（ヒント1段階目まで）"))
        #expect(text.contains("棒グラフの読み取り：まだ解けていない"))
        #expect(text.contains("苦手な単元（weak_points）：割合の文章題"))
        #expect(text.contains("子ども：これ見て、割合わかんない\n先生：どれどれ。何を聞かれてるかな？\n子ども：もとにする量だ！"))
        #expect(text.contains("集中した時間：35分"))
        #expect(!text.contains("toolu_1"))
        // 「要確認」はふり返りに渡さない（記憶に入れないように）
        #expect(!text.contains("けんか"))
    }

    @Test func レスポンスからふり返りを読む() throws {
        let reflection = try SessionReflector.parseResponse(Data(Self.response().utf8))
        #expect(reflection.summary.hasPrefix("割合の文章題と"))
        #expect(reflection.teacherNote == "割合の問題で、もとにする量を自分で見つけられました！")
        #expect(reflection.spokenClosing.contains("2問"))
        #expect(reflection.memoryUpdates[.likes] == .init(add: ["サッカー"], remove: []))
        #expect(reflection.memoryUpdates[.weakPoints] == .init(add: ["棒グラフの読み取り"], remove: ["割合の文章題"]))
        #expect(reflection.memoryUpdates[.events] == .init())
    }

    @Test func max_tokensで切れたりツールがなかったりしたら失敗にする() throws {
        #expect(throws: SessionReflectorError.noReflection(stopReason: "max_tokens")) {
            try SessionReflector.parseResponse(Data(Self.response(stopReason: "max_tokens").utf8))
        }
        let textOnly = #"{"stop_reason":"end_turn","content":[{"type":"text","text":"おつかれ"}]}"#
        #expect(throws: SessionReflectorError.noReflection(stopReason: "end_turn")) {
            try SessionReflector.parseResponse(Data(textOnly.utf8))
        }
        #expect(throws: SessionReflectorError.emptyReflection) {
            try SessionReflector.parseResponse(Data(Self.response(closing: "  ").utf8))
        }
    }

    @Test func 終わりにセッションとフラグと記憶を保存してふり返りを返す() async throws {
        let transport = MockTransport(body: Self.response())
        let store = try SwiftDataMemoryStore.inMemory()
        try await store.replaceMemories(category: .weakPoints, with: [
            MemoryRecord(category: .weakPoints, content: "割合の文章題", updatedAt: start),
        ])
        let now = start.addingTimeInterval(3_000)
        let finished = try await makeReflector(transport).finish(input, store: store, now: now)

        #expect(finished.usedClaude)
        #expect(finished.spokenClosing.hasPrefix("今日は2問やったね！"))

        let saved = try #require(try await store.latestSession())
        #expect(saved == finished.session)
        #expect(saved.id == "S-1")
        #expect(saved.focusMinutes == 35)
        #expect(saved.summary.hasPrefix("割合の文章題と"))
        #expect(saved.teacherNote == "割合の問題で、もとにする量を自分で見つけられました！")
        #expect(saved.flags == ["学校で友だちとけんかしたと話していた"])
        #expect(saved.problems == input.problems)
        #expect(saved.syncedAt == nil)

        #expect(try await store.memories(category: .likes).map(\.content) == ["サッカー"])
        #expect(try await store.memories(category: .weakPoints).map(\.content) == ["棒グラフの読み取り"])
    }

    @Test func Claudeが失敗してもセッションと要確認を保存し決まり文句でふり返る() async throws {
        let transport = MockTransport(status: 502, body: #"{"error":"upstream"}"#)
        let store = try SwiftDataMemoryStore.inMemory()
        try await store.replaceMemories(category: .likes, with: [MemoryRecord(category: .likes, content: "サッカー", updatedAt: start)])
        let finished = try await makeReflector(transport).finish(input, store: store)

        #expect(!finished.usedClaude)
        #expect(finished.spokenClosing == "今日は2問やったね。そのうち1問は自分の力で解けたね！おつかれさま、また一緒にやろうね！")
        let saved = try #require(try await store.latestSession())
        #expect(saved.flags == ["学校で友だちとけんかしたと話していた"])
        #expect(saved.summary.contains("2問に取り組んだ（自力 1問）"))
        #expect(saved.problems.count == 2)
        // 記憶はそのまま
        #expect(try await store.memories().map(\.content) == ["サッカー"])
    }

    @Test func 問題がないときの決まり文句() {
        var empty = input
        empty.problems = []
        let reflection = SessionReflector.fallback(for: empty)
        #expect(reflection.spokenClosing.hasPrefix("今日もおつかれさま！"))
        #expect(reflection.memoryUpdates.isEmpty)
    }

    @Test func 長い会話は後ろを残して前を省く() {
        let messages = (0..<100).map { ChatMessage(role: .user, content: [.text("発話\($0)")]) }
        let text = SessionReflector.transcriptText(messages, limit: 50)
        #expect(text.hasPrefix("（前半は省略）\n"))
        #expect(text.hasSuffix("子ども：発話99"))
        #expect(SessionReflector.transcriptText([], limit: 50) == "（会話なし）")
    }
}
