import Foundation
import Testing
@testable import HomeTeacher

/// 実際の API のストリーム（2026-11-06 に本番の Worker 経由で確かめた形）に合わせた検索の応答。
private enum SearchSSE {
    static func line(_ json: String) -> String { "data: \(json)\n\n" }

    static let start = line(#"{"type":"message_start","message":{"id":"m","role":"assistant","content":[]}}"#)
    static let stop = line(#"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#) + line(#"{"type":"message_stop"}"#)

    static func text(_ index: Int, _ text: String) -> String {
        line(#"{"type":"content_block_start","index":\#(index),"content_block":{"type":"text","text":""}}"#)
            + line(#"{"type":"content_block_delta","index":\#(index),"delta":{"type":"text_delta","text":"\#(text)"}}"#)
            + line(#"{"type":"content_block_stop","index":\#(index)}"#)
    }

    static func search(_ index: Int, query: String) -> String {
        line(#"{"type":"content_block_start","index":\#(index),"content_block":{"type":"server_tool_use","id":"srvtoolu_1","name":"web_search","input":{}}}"#)
            + line(#"{"type":"content_block_delta","index":\#(index),"delta":{"type":"input_json_delta","partial_json":"{\"query\": \"\#(query)\"}"}}"#)
            + line(#"{"type":"content_block_stop","index":\#(index)}"#)
    }

    static func results(_ index: Int) -> String {
        line(#"{"type":"content_block_start","index":\#(index),"content_block":{"type":"web_search_tool_result","tool_use_id":"srvtoolu_1","content":[{"type":"web_search_result","title":"あ","url":"https://tenki.jp/a","encrypted_content":"x","page_age":"0 days ago"},{"type":"web_search_result","title":"い","url":"https://tenki.jp/b","encrypted_content":"x"},{"type":"web_search_result","title":"う","url":"https://ja.wikipedia.org/wiki/c","encrypted_content":"x"}]}}"#)
            + line(#"{"type":"content_block_stop","index":\#(index)}"#)
    }

    static func failedResults(_ index: Int) -> String {
        line(#"{"type":"content_block_start","index":\#(index),"content_block":{"type":"web_search_tool_result","tool_use_id":"srvtoolu_1","content":{"type":"web_search_tool_result_error","error_code":"max_uses_exceeded"}}}"#)
            + line(#"{"type":"content_block_stop","index":\#(index)}"#)
    }
}

struct TeacherBrainResearchTests {
    private let webSearch: JSONValue = .object(["type": .string("web_search_20250305"), "name": .string("web_search")])

    private func makeBrain(_ transport: MockTransport) -> TeacherBrain {
        let client = WorkerClient(baseURL: URL(string: "https://example.workers.dev")!, familyToken: "t", transport: transport)
        return TeacherBrain(client: client, systemPrompt: "S", serverTools: [webSearch])
    }

    private func collect(_ brain: TeacherBrain, _ text: String) async throws -> [TeacherOutput] {
        var out: [TeacherOutput] = []
        for try await output in await brain.respondWithBoards(to: text) { out.append(output) }
        return out
    }

    private var searchReply: String {
        SearchSSE.start + SearchSSE.text(0, "ちょっと調べてみるね。") + SearchSSE.search(1, query: "天気 今週")
            + SearchSSE.results(2) + SearchSSE.text(3, "東京は晴れだって。") + SearchSSE.stop
    }

    @Test func 検索の前の文を先に流し様子を順に流す() async throws {
        let outputs = try await collect(makeBrain(MockTransport(body: searchReply)), "今週の天気は？")
        #expect(outputs == [
            .sentence("ちょっと調べてみるね。"),
            .research(.searching(query: "天気 今週")),
            .research(.found(query: "天気 今週", sites: ["tenki.jp", "ja.wikipedia.org"])),
            .sentence("東京は晴れだって。"),
        ])
    }

    @Test func 検索の結果は履歴に残さず話した言葉だけ残す() async throws {
        let brain = makeBrain(MockTransport(body: searchReply))
        _ = try await collect(brain, "今週の天気は？")
        #expect(await brain.history.messages == [
            ChatMessage(role: .user, content: [.text("今週の天気は？")]),
            ChatMessage(role: .assistant, content: [.text("ちょっと調べてみるね。東京は晴れだって。")]),
        ])
    }

    @Test func 検索の失敗は様子で伝えて返事は続ける() async throws {
        let body = SearchSSE.start + SearchSSE.search(0, query: "天気") + SearchSSE.failedResults(1)
            + SearchSSE.text(2, "うまく調べられなかったよ。") + SearchSSE.stop
        let outputs = try await collect(makeBrain(MockTransport(body: body)), "天気は？")
        #expect(outputs == [
            .research(.searching(query: "天気")),
            .research(.failed(query: "天気")),
            .sentence("うまく調べられなかったよ。"),
        ])
    }

    @Test func リクエストにサーバーツールをそのまま入れる() async throws {
        let transport = MockTransport(body: SSEFixture.textStream(["うん。"]))
        let brain = makeBrain(transport)
        _ = try await collect(brain, "こんにちは")
        let body = try #require(await transport.requestBodies().first)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let tools = try #require(json["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        #expect(tools[0]["type"] as? String == "web_search_20250305")
        #expect(tools[0]["input_schema"] == nil)
    }

    @Test func 検索を断られたら検索なしでやり直して会話を止めない() async throws {
        let transport = MockTransport(responses: [
            .init(status: 400, body: #"{"type":"error","error":{"type":"invalid_request_error","message":"The following domains are not accessible"}}"#),
            .init(body: SSEFixture.textStream(["先生もわからないや。"])),
            .init(body: SSEFixture.textStream(["うん。"])),
        ])
        let brain = makeBrain(transport)
        let outputs = try await collect(brain, "天気は？")
        #expect(outputs == [.sentence("先生もわからないや。")])
        #expect(await brain.isSearchUnavailable)
        // 以後は検索を渡さない
        _ = try await collect(brain, "そっか")
        let bodies = await transport.requestBodies()
        #expect(bodies.count == 3)
        for body in bodies.dropFirst() {
            let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(json["tools"] == nil)
        }
    }

    @Test func 検索なしのブレインは400をそのまま投げる() async throws {
        let client = WorkerClient(
            baseURL: URL(string: "https://example.workers.dev")!, familyToken: "t",
            transport: MockTransport(status: 400, body: #"{"error":"x"}"#)
        )
        let brain = TeacherBrain(client: client, systemPrompt: "S")
        await #expect(throws: (any Error).self) { _ = try await collect(brain, "天気は？") }
    }
}

struct WebSearchToolTests {
    @Test func サイトは順番どおりに重ならず並ぶ() {
        let sites = WebSearchTool.sites(from: [
            .init(title: "", url: "https://tenki.jp/a"), .init(title: "", url: "https://TENKI.jp/b"),
            .init(title: "", url: "https://www.jma.go.jp/c"), .init(title: "", url: "こわれたURL"),
        ])
        #expect(sites == ["tenki.jp", "www.jma.go.jp"])
    }

    @Test func 結果が空なら見つからなかった扱い() {
        #expect(ResearchUpdate(results: [], errorCode: nil, query: "q") == .failed(query: "q"))
    }

    @Test func 読み上げからマークダウンを除く() {
        #expect(SpeechText.clean("**今日は晴れ**だよ。") == "今日は晴れだよ。")
        #expect(SpeechText.clean("## 見出し") == "見出し")
        #expect(SpeechText.clean("- 東京は晴れ") == "東京は晴れ")
        #expect(SpeechText.clean("3-2は1だよ。") == "3-2は1だよ。")
    }

    @Test func 今日の日付を日本時間で書く() {
        // 2026-11-05 15:30 UTC = 2026-11-06 00:30 JST（金）
        let date = Date(timeIntervalSince1970: 1_793_892_600)
        #expect(PromptLibrary.todayLabel(date) == "2026年11月6日（金）")
    }

    @Test func 同梱の定義は検索の形() throws {
        let tools = try PromptLibrary().conversationServerTools()
        guard case .object(let fields)? = tools.first else { Issue.record("オブジェクトではない"); return }
        #expect(fields["name"] == .string("web_search"))
        #expect(fields["type"] == .string("web_search_20250305"))
    }
}
