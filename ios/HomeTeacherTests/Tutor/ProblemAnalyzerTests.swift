import Foundation
import Testing
import UIKit
@testable import HomeTeacher

struct ProblemAnalyzerTests {
    private func makeAnalyzer(_ transport: MockTransport, includeBoardTools: Bool = true) -> ProblemAnalyzer {
        let client = WorkerClient(baseURL: URL(string: "https://example.workers.dev")!, familyToken: "t", transport: transport)
        return ProblemAnalyzer(client: client, includeBoardTools: includeBoardTools)
    }

    private func json(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static let jpeg: Data = {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }
        return ImageResizer.jpegData(from: image)!
    }()

    static let thinkingInput = #"""
        {"kind":"thinking","problem_summary":"たて4cm、横6cmの長方形の面積を求める","answer":"24cm²",
         "answer_variants":["24平方センチメートル","二十四"],"solution":"たて×横で4×6=24",
         "hint_steps":["何を求める問題かな？","長さが書いてあるところはどこ？","面積はどうやって求めたっけ？","4×6を一緒に計算しよう。ということは？"],
         "essay_guidance":""}
        """#

    /// 非ストリーミングの Messages API の応答。
    static func response(blocks: [String], stopReason: String = "tool_use") -> String {
        #"{"id":"msg_1","type":"message","role":"assistant","model":"claude-sonnet-5-5","content":["#
            + blocks.joined(separator: ",")
            + #"],"stop_reason":"\#(stopReason)","usage":{"input_tokens":10,"output_tokens":10}}"#
    }

    static func toolUse(_ name: String, _ input: String, id: String = "toolu_1") -> String {
        #"{"type":"tool_use","id":"\#(id)","name":"\#(name)","input":\#(input)}"#
    }

    // MARK: リクエスト

    @Test func リクエストはSonnetに画像と会話を渡しreport_analysisを強制する() async throws {
        let transport = MockTransport(body: Self.response(blocks: [Self.toolUse("report_analysis", Self.thinkingInput)]))
        let conversation = [
            ChatMessage(role: .user, content: [.text("ねえ先生、これ見て")]),
            ChatMessage(role: .assistant, content: [.text("どれどれ？"), .toolUse(id: "toolu_x", name: "flag_for_parent", input: .object([:]))]),
            ChatMessage(role: .user, content: [.toolResult(toolUseID: "toolu_x", content: "記録しました。")]),
        ]
        _ = try await makeAnalyzer(transport).analyze(jpegData: Self.jpeg, conversation: conversation)

        let request = try #require(await transport.requests.first)
        #expect(request.url?.path() == "/v1/claude")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer t")
        let body = try json(try #require(await transport.requestBodies().first))
        #expect(body["model"] as? String == "claude-sonnet-5-5")
        #expect(body["stream"] as? Bool == false)
        #expect(body["max_tokens"] as? Int == 4096)
        #expect(body["thinking"] == nil)

        let toolChoice = try #require(body["tool_choice"] as? [String: Any])
        #expect(toolChoice["type"] as? String == "tool")
        #expect(toolChoice["name"] as? String == "report_analysis")

        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(tools.map { $0["name"] as? String } == ["report_analysis", "show_board", "render_svg"])
        #expect(tools.allSatisfy { $0["strict"] as? Bool == true })

        let system = try #require(body["system"] as? String)
        #expect(system.contains("report_analysis"))
        #expect(system.contains("ヒントの出し方"))
        #expect(!system.contains("{{"))

        // メッセージは user 1つ：画像 → 会話の文字。ツールの履歴は文字だけにする
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages[0]["role"] as? String == "user")
        let content = try #require(messages[0]["content"] as? [[String: Any]])
        #expect(content.map { $0["type"] as? String } == ["image", "text"])
        let source = try #require(content[0]["source"] as? [String: Any])
        #expect(source["type"] as? String == "base64")
        #expect(source["media_type"] as? String == "image/jpeg")
        let base64 = try #require(source["data"] as? String)
        let bytes = try #require(Data(base64Encoded: base64))
        #expect(Array(bytes.prefix(2)) == [0xFF, 0xD8])
        let text = try #require(content[1]["text"] as? String)
        #expect(text.contains("子ども：ねえ先生、これ見て"))
        #expect(text.contains("先生：どれどれ？"))
        #expect(text.contains("写真の ID：photo_1"))
        #expect(!text.contains("記録しました"))
    }

    @Test func 黒板のツールを渡さない設定ではreport_analysisだけ() throws {
        let analyzer = makeAnalyzer(MockTransport(body: ""), includeBoardTools: false)
        let body = try analyzer.makeRequestBody(jpegData: Self.jpeg, conversation: [], imageID: "p")
        let tools = try #require(body["tools"]?.testArray)
        #expect(tools.map { $0["name"]?.stringValue } == ["report_analysis"])
        #expect(try analyzer.systemPrompt().contains("# 黒板の部品カタログ") == false)
        let withBoard = makeAnalyzer(MockTransport(body: ""), includeBoardTools: true)
        #expect(try withBoard.systemPrompt().contains("# 黒板の部品カタログ"))
    }

    @Test func 会話は直近だけを文字にする() {
        let messages = (1...20).map { ChatMessage(role: $0 % 2 == 1 ? .user : .assistant, content: [.text("発言\($0)")]) }
        let transcript = ProblemAnalyzer.transcript(of: messages, limit: 3)
        #expect(transcript == "先生：発言18\n子ども：発言19\n先生：発言20")
    }

    // MARK: スキーマ

    @Test func スキーマはstrictの条件を満たす() throws {
        let schema = AnalysisTool.inputSchema
        #expect(strictViolations(schema, path: "$").isEmpty, "\(strictViolations(schema, path: "$"))")
        let properties = try #require(schema["properties"]?.testObject)
        #expect(Set(properties.keys) == ["kind", "problem_summary", "answer", "answer_variants", "solution", "hint_steps", "essay_guidance"])
        #expect(properties["kind"]?["enum"] == .array([.string("reading"), .string("thinking"), .string("writing")]))
        #expect(AnalysisTool.definition["strict"] == .bool(true))
    }

    /// 全オブジェクトに additionalProperties: false と、全キーの required があるか。strict 非対応の制約がないか。
    private func strictViolations(_ schema: JSONValue, path: String) -> [String] {
        guard case .object(let o) = schema else { return [] }
        var out: [String] = []
        for key in ["minimum", "maximum", "minLength", "maxLength", "minItems", "maxItems", "pattern"] where o[key] != nil {
            out.append("\(path): \(key) は strict 非対応")
        }
        if o["type"] == .string("object") {
            if o["additionalProperties"] != .bool(false) { out.append("\(path): additionalProperties") }
            guard case .object(let props)? = o["properties"] else { return out + ["\(path): properties がない"] }
            let required = Set((o["required"]?.testArray ?? []).compactMap(\.stringValue))
            if required != Set(props.keys) { out.append("\(path): required が全キーでない") }
            for (k, v) in props { out += strictViolations(v, path: "\(path).\(k)") }
        }
        if let items = o["items"] { out += strictViolations(items, path: "\(path)[]") }
        if case .array(let branches)? = o["anyOf"] {
            for (i, b) in branches.enumerated() { out += strictViolations(b, path: "\(path)|\(i)") }
        }
        return out
    }

    // MARK: デコード

    @Test func 分析結果をデコードする() async throws {
        let transport = MockTransport(body: Self.response(blocks: [Self.toolUse("report_analysis", Self.thinkingInput)]))
        let result = try await makeAnalyzer(transport).analyze(jpegData: Self.jpeg)
        #expect(result.analysis == ProblemAnalysis(
            kind: .thinking,
            problemSummary: "たて4cm、横6cmの長方形の面積を求める",
            answer: "24cm²",
            answerVariants: ["24平方センチメートル", "二十四"],
            solution: "たて×横で4×6=24",
            hintSteps: ["何を求める問題かな？", "長さが書いてあるところはどこ？", "面積はどうやって求めたっけ？", "4×6を一緒に計算しよう。ということは？"],
            essayGuidance: ""
        ))
        #expect(result.boards.isEmpty)
    }

    @Test func ヒントの数を段階の数に揃える() throws {
        let short = try AnalysisTool.decode(try JSONDecoder().decode(JSONValue.self, from: Data(#"""
            {"kind":"reading","problem_summary":"s","answer":" イ ","answer_variants":["", "い"],"solution":"",
             "hint_steps":["1段目","  "],"essay_guidance":""}
            """#.utf8)))
        #expect(short.hintSteps.count == 4)
        #expect(short.hintSteps[0] == "1段目")
        #expect(short.hintSteps[1] == HintStage.whereToLook.fallbackHint)
        #expect(short.hintSteps[3] == HintStage.walkThrough.fallbackHint)
        #expect(short.answer == "イ")
        #expect(short.answerVariants == ["い"])

        let long = ProblemAnalysis(kind: .writing, problemSummary: "", answer: "", hintSteps: ["a", "b", "c", "d", "e"]).normalized()
        #expect(long.hintSteps == ["a", "b", "c"])
    }

    @Test func 作文の分析をデコードする() throws {
        let data = Self.response(blocks: [Self.toolUse("report_analysis", #"""
            {"kind":"writing","problem_summary":"「わたしの宝物」という題で400字の作文を書く","answer":"","answer_variants":[],
             "solution":"","hint_steps":["宝物を3つ思いうかべよう","はじめ・なか・おわりを決めよう","具体的な場面があるか見る"],
             "essay_guidance":"400字・3段落。宝物にまつわる思い出を1つにしぼる"}
            """#)])
        let result = try ProblemAnalyzer.decodeResponse(Data(data.utf8))
        #expect(result.analysis.kind == .writing)
        #expect(result.analysis.answer.isEmpty)
        #expect(result.analysis.essayGuidance.contains("400字"))
        #expect(HintLadder(analysis: result.analysis).stages == [.organize, .structure, .review])
    }

    @Test func 黒板の呼び出しもあれば黒板の中身にする() throws {
        let data = Self.response(blocks: [
            #"{"type":"thinking","thinking":"…","signature":"x"}"#,
            #"{"type":"text","text":"分析します"}"#,
            Self.toolUse("report_analysis", Self.thinkingInput),
            Self.toolUse("show_board", #"{"title":"考える順番","component":{"type":"step_cards","steps":[{"heading":"何を聞かれている？","detail":"面積"}]}}"#, id: "toolu_2"),
        ])
        let result = try ProblemAnalyzer.decodeResponse(Data(data.utf8))
        #expect(result.analysis.kind == .thinking)
        #expect(result.boards == [.component(
            title: "考える順番",
            .stepCards(StepCards(steps: [.init(heading: "何を聞かれている？", detail: "面積")]))
        )])
    }

    @Test func report_analysisがなければエラー() {
        let data = Self.response(blocks: [#"{"type":"text","text":"すみません"}"#], stopReason: "end_turn")
        #expect(throws: ProblemAnalyzerError.missingAnalysis) { try ProblemAnalyzer.decodeResponse(Data(data.utf8)) }
    }

    @Test func max_tokensで切れたらエラー() {
        let data = Self.response(blocks: [Self.toolUse("report_analysis", #"{"kind":"thinking"}"#)], stopReason: "max_tokens")
        #expect(throws: ProblemAnalyzerError.truncated) { try ProblemAnalyzer.decodeResponse(Data(data.utf8)) }
    }

    @Test func 知らない種類はデコードエラー() {
        let input = Self.thinkingInput.replacingOccurrences(of: #""thinking""#, with: #""music""#)
        let data = Self.response(blocks: [Self.toolUse("report_analysis", input)])
        #expect(throws: ProblemAnalyzerError.self) { try ProblemAnalyzer.decodeResponse(Data(data.utf8)) }
    }

    @Test func Workerのエラーはそのまま投げる() async {
        let transport = MockTransport(status: 400, body: #"{"error":"model not allowed"}"#)
        await #expect(throws: WorkerError.http(status: 400, body: #"{"error":"model not allowed"}"#)) {
            try await makeAnalyzer(transport).analyze(jpegData: Self.jpeg)
        }
    }
}

private extension JSONValue {
    var testArray: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    var testObject: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }
}
