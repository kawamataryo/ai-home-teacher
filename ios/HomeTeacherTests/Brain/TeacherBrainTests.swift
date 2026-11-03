import Foundation
import Testing
@testable import HomeTeacher

struct TeacherBrainTests {
    private func makeBrain(
        _ transport: MockTransport,
        systemPrompt: String = "あなたは先生です。",
        tools: [ToolDefinition] = []
    ) -> TeacherBrain {
        let client = WorkerClient(baseURL: URL(string: "https://example.workers.dev")!, familyToken: "t", transport: transport)
        return TeacherBrain(client: client, systemPrompt: systemPrompt, tools: tools)
    }

    private func json(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> [String] {
        var out: [String] = []
        for try await s in stream { out.append(s) }
        return out
    }

    @Test func 文ごとに流して履歴に残す() async throws {
        let transport = MockTransport(body: SSEFixture.textStream(["お、いい", "ね！どこが", "むずかしい？", "一緒に見よう"]))
        let brain = makeBrain(transport)

        let sentences = try await collect(await brain.respond(to: "ねえ先生、これわかんない"))
        #expect(sentences == ["お、いいね！", "どこがむずかしい？", "一緒に見よう"])
        #expect(await brain.history.messages == [
            ChatMessage(role: .user, content: [.text("ねえ先生、これわかんない")]),
            ChatMessage(role: .assistant, content: [.text("お、いいね！どこがむずかしい？一緒に見よう")]),
        ])
    }

    @Test func リクエストはHaikuでストリーミングしシステムプロンプトと履歴を送る() async throws {
        let transport = MockTransport(responses: [
            .init(body: SSEFixture.textStream(["うん。"])),
            .init(body: SSEFixture.textStream(["そうそう。"])),
        ])
        let brain = makeBrain(transport, systemPrompt: "SYSTEM")
        _ = try await collect(await brain.respond(to: "1回目"))
        _ = try await collect(await brain.respond(to: "2回目"))

        let request = try #require(await transport.requests.last)
        #expect(request.url?.path() == "/v1/claude")
        let body = try #require(await transport.requestBodies().last)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "claude-haiku-5-5")
        #expect(json["stream"] as? Bool == true)
        // プロンプトキャッシュ：system の最後（ツール ＋ system）と、最上位の自動キャッシュ（履歴）に印を付ける
        let system = try #require(json["system"] as? [[String: Any]])
        #expect(system.count == 1)
        #expect(system[0]["type"] as? String == "text")
        #expect(system[0]["text"] as? String == "SYSTEM")
        #expect((system[0]["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
        #expect((json["cache_control"] as? [String: Any])?["type"] as? String == "ephemeral")
        // 黒板の図（show_board の入力）も返事に入るので、512 では足りない
        #expect(json["max_tokens"] as? Int == 1024)
        #expect((json["thinking"] as? [String: Any])?["type"] as? String == "disabled")
        #expect(json["tools"] == nil)

        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["user", "assistant", "user"])
        let first = try #require(messages[0]["content"] as? [[String: Any]])
        #expect(first[0]["type"] as? String == "text")
        #expect(first[0]["text"] as? String == "1回目")
        let second = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(second[0]["text"] as? String == "うん。")
    }

    @Test func 先生のメモはキャッシュの印より後ろに送る() async throws {
        let prompt = try PromptLibrary().conversationSystemPrompt(teacherNote: "- 正答: 24")
        let transport = MockTransport(body: SSEFixture.textStream(["うん。"]))
        let brain = makeBrain(transport, systemPrompt: prompt)
        _ = try await collect(await brain.respond(to: "先生"))

        let body = try json(try #require(await transport.requestBodies().first))
        let blocks = try #require(body["system"] as? [[String: Any]])
        #expect(blocks.count == 2)
        #expect(blocks[0]["cache_control"] != nil)
        #expect(blocks[1]["cache_control"] == nil)
        #expect((blocks[1]["text"] as? String)?.contains("- 正答: 24") == true)
        #expect(systemText(body) == prompt)
    }

    @Test func 同梱のプロンプトをシステムプロンプトとして送る() async throws {
        let prompt = try PromptLibrary().conversationSystemPrompt()
        let transport = MockTransport(body: SSEFixture.textStream(["うん。"]))
        let brain = makeBrain(transport, systemPrompt: prompt)
        _ = try await collect(await brain.respond(to: "先生"))

        let body = try #require(await transport.requestBodies().first)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let system = try #require(systemText(json))
        #expect(system.contains("ハル先生"))
        #expect(!system.contains("{{"))
    }

    @Test func 先生から話し始めた履歴は先頭にuserを足して送る() async throws {
        let brain = makeBrain(MockTransport(body: ""))
        await brain.recordTeacherUtterance("昨日の割合の続き、やる？")
        await brain.recordUserUtterance("やる")
        let request = await brain.makeRequest()
        #expect(request.messages.map(\.role) == [.user, .assistant, .user])
        #expect(request.messages[1].text == "昨日の割合の続き、やる？")
    }

    @Test func 途中のエラーイベントで投げる() async throws {
        let body = """
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"えっと。"}}
        data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}
        """
        let brain = makeBrain(MockTransport(body: body))
        await #expect(throws: TeacherBrainError.api(type: "overloaded_error", message: "Overloaded")) {
            for try await _ in await brain.respond(to: "先生") {}
        }
        // エラーの前に届いた分は履歴に残る
        #expect(await brain.history.lastAssistantText == "えっと。")
    }

    @Test func HTTPのエラーで投げる() async {
        let brain = makeBrain(MockTransport(status: 401, body: #"{"error":"unauthorized"}"#))
        await #expect(throws: WorkerError.http(status: 401, body: #"{"error":"unauthorized"}"#)) {
            for try await _ in await brain.respond(to: "先生") {}
        }
    }

    @Test func 割り込みで再生した位置まで切り詰める() async throws {
        let transport = MockTransport(body: SSEFixture.textStream(["どれどれ。表の2行目を見てみよう。"]))
        let brain = makeBrain(transport)
        _ = try await collect(await brain.respond(to: "これ見て"))
        await brain.truncateLastReply(toCharacterCount: 5)
        #expect(await brain.history.lastAssistantText == "どれどれ。")
    }

    // MARK: - 要確認のフラグ（flag_for_parent）

    private static let flagInput = #"{"category":"bullying","reason":"学校で無視されていると話した。"}"#

    @Test func ツールの定義をリクエストに入れる() async throws {
        let tools = try PromptLibrary().conversationTools()
        let transport = MockTransport(body: SSEFixture.textStream(["うん。"]))
        let brain = makeBrain(transport, tools: tools)
        _ = try await collect(await brain.respond(to: "先生"))

        let body = try json(try #require(await transport.requestBodies().first))
        let sent = try #require(body["tools"] as? [[String: Any]])
        #expect(sent.map { $0["name"] as? String } == ["flag_for_parent", "show_board"])
        let schema = try #require(sent[0]["input_schema"] as? [String: Any])
        #expect(schema["required"] as? [String] == ["category", "reason"])
        // strict は書いたツールだけに付ける
        #expect(sent[0]["strict"] == nil)
        #expect(sent[1]["strict"] as? Bool == false)
    }

    @Test func 言葉で返事をしてからフラグを立てたら記録して続けて呼ばない() async throws {
        let transport = MockTransport(body: SSEFixture.toolStream(
            text: "話してくれてありがとう。お母さんにも話してみよう？", inputJSON: Self.flagInput
        ))
        let brain = makeBrain(transport)

        let sentences = try await collect(await brain.respond(to: "学校でずっと無視されてる"))
        #expect(sentences == ["話してくれてありがとう。", "お母さんにも話してみよう？"])

        let flags = await brain.sessionFlags
        #expect(flags.needsReview.map(\.category) == [.bullying])
        #expect(flags.needsReview.map(\.reason) == ["学校で無視されていると話した。"])
        #expect(await transport.requests.count == 1)

        // 履歴は tool_use と tool_result が対になっている
        let messages = await brain.history.messages
        #expect(messages.map(\.role) == [.user, .assistant, .user])
        #expect(messages[1].content.last == .toolUse(
            id: "toolu_1", name: "flag_for_parent",
            input: .object(["category": .string("bullying"), "reason": .string("学校で無視されていると話した。")])
        ))
        #expect(messages[2].content == [.toolResult(toolUseID: "toolu_1", content: TeacherBrain.toolResultText)])

        // 次の子どもの発話は tool_result と同じ user メッセージにまとまる
        await brain.recordUserUtterance("うん")
        let next = await brain.makeRequest()
        #expect(next.messages.last?.content == [
            .toolResult(toolUseID: "toolu_1", content: TeacherBrain.toolResultText), .text("うん"),
        ])
    }

    @Test func ツールだけで言葉がなければtool_resultを付けてもう一度呼ぶ() async throws {
        let transport = MockTransport(responses: [
            .init(body: SSEFixture.toolStream(text: "", inputJSON: Self.flagInput)),
            .init(body: SSEFixture.textStream(["そっか、つらかったね。", "おうちの人に話してみよう？"])),
        ])
        let brain = makeBrain(transport)

        let sentences = try await collect(await brain.respond(to: "学校でずっと無視されてる"))
        #expect(sentences == ["そっか、つらかったね。", "おうちの人に話してみよう？"])
        #expect(await brain.sessionFlags.needsReview.count == 1)

        let bodies = await transport.requestBodies()
        #expect(bodies.count == 2)
        let second = try json(bodies[1])
        let messages = try #require(second["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["user", "assistant", "user"])
        let toolResult = try #require((messages[2]["content"] as? [[String: Any]])?.first)
        #expect(toolResult["type"] as? String == "tool_result")
        #expect(toolResult["tool_use_id"] as? String == "toolu_1")
        let toolUse = try #require((messages[1]["content"] as? [[String: Any]])?.first)
        #expect(toolUse["type"] as? String == "tool_use")

        #expect(await brain.history.lastAssistantText == "そっか、つらかったね。おうちの人に話してみよう？")
    }

    @Test func ツールを呼び続けても続きは1回まで() async throws {
        let transport = MockTransport(responses: [
            .init(body: SSEFixture.toolStream(text: "", toolID: "a", inputJSON: Self.flagInput)),
            .init(body: SSEFixture.toolStream(text: "", toolID: "b", inputJSON: Self.flagInput)),
            .init(body: SSEFixture.textStream(["呼ばれないはず。"])),
        ])
        let brain = makeBrain(transport)
        let sentences = try await collect(await brain.respond(to: "x"))
        #expect(sentences.isEmpty)
        #expect(await transport.requests.count == 2)
    }

    @Test func 知らないツールにもtool_resultを返しフラグにはしない() async throws {
        let transport = MockTransport(body: SSEFixture.toolStream(text: "うん。", name: "unknown_tool", inputJSON: "{}"))
        let brain = makeBrain(transport)
        _ = try await collect(await brain.respond(to: "x"))
        #expect(await brain.sessionFlags.needsReview.isEmpty)
        let last = await brain.history.messages.last
        #expect(last?.content == [.toolResult(toolUseID: "toolu_1", content: "未対応のツールです。")])
    }

    @Test func 通信中に止めたら途中の文を流さずに静かに終わる() async throws {
        let delta = "data: " + SSEFixture.json([
            "type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": "どれどれ。表の"],
        ])
        let transport = HangingTransport(lines: [delta])
        let client = WorkerClient(baseURL: URL(string: "https://example.workers.dev")!, familyToken: "t", transport: transport)
        let brain = TeacherBrain(client: client, systemPrompt: "s")

        var iterator = await brain.respond(to: "これ見て").makeAsyncIterator()
        #expect(try await iterator.next() == "どれどれ。")
        await brain.cancel()
        // 「表の」は流れず、エラーにもならずに終わる
        #expect(try await iterator.next() == nil)
        // 届いた分は履歴に残る（このあと再生した位置で切り詰める）
        #expect(await brain.history.lastAssistantText == "どれどれ。表の")
        #expect(await transport.requestCount == 1)
    }

    @Test func ツールだけの返事の途中で止めたら続きを呼ばない() async throws {
        // tool_use の block は終わったが、message_stop の前で止める
        let lines = SSEFixture.toolStream(text: "", inputJSON: Self.flagInput)
            .split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            .filter { !$0.contains("message_stop") }
        let transport = HangingTransport(lines: lines)
        let client = WorkerClient(baseURL: URL(string: "https://example.workers.dev")!, familyToken: "t", transport: transport)
        let brain = TeacherBrain(client: client, systemPrompt: "s")

        var iterator = await brain.respond(to: "x").makeAsyncIterator()
        // フラグが記録されるまで待つ
        for _ in 0..<1000 where await brain.sessionFlags.needsReview.isEmpty {
            await Task.yield()
        }
        #expect(await brain.sessionFlags.needsReview.count == 1)
        await brain.cancel()
        #expect(try await iterator.next() == nil)
        #expect(await transport.requestCount == 1)
    }
}
