import Foundation
import Testing
@testable import HomeTeacher

struct TeacherBrainTests {
    private func makeBrain(_ transport: MockTransport, systemPrompt: String = "あなたは先生です。") -> TeacherBrain {
        let client = WorkerClient(baseURL: URL(string: "https://example.workers.dev")!, familyToken: "t", transport: transport)
        return TeacherBrain(client: client, systemPrompt: systemPrompt)
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
        #expect(json["system"] as? String == "SYSTEM")
        #expect(json["max_tokens"] as? Int == 512)
        #expect(json["tools"] == nil)

        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["user", "assistant", "user"])
        let first = try #require(messages[0]["content"] as? [[String: Any]])
        #expect(first[0]["type"] as? String == "text")
        #expect(first[0]["text"] as? String == "1回目")
        let second = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(second[0]["text"] as? String == "うん。")
    }

    @Test func 同梱のプロンプトをシステムプロンプトとして送る() async throws {
        let prompt = try PromptLibrary().conversationSystemPrompt()
        let transport = MockTransport(body: SSEFixture.textStream(["うん。"]))
        let brain = makeBrain(transport, systemPrompt: prompt)
        _ = try await collect(await brain.respond(to: "先生"))

        let body = try #require(await transport.requestBodies().first)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let system = try #require(json["system"] as? String)
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
}
