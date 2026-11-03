import Foundation
import Testing
@testable import HomeTeacher

@Suite(.timeLimit(.minutes(1)))
struct DecisionClientTests {
    private func client(_ transport: any HTTPTransport, timeout: Duration = .milliseconds(800)) -> DecisionClient {
        DecisionClient(worker: DecisionFixture.worker(transport), timeout: timeout)
    }

    // MARK: - リクエストの形

    @Test func 型の違う質問を1回のリクエストにまとめて送る() async throws {
        let transport = MockTransport(body: #"{"answers":{}}"#)
        _ = await client(transport).decide(
            state: .fields(["utterance": "これ見て"]),
            questions: [
                "a": .boolean(instructions: "先生への発話か", whenTrue: "先生に話している", whenFalse: "独り言"),
                "b": .choice(instructions: "意図", options: [.init(name: "質問", description: "たずねている"), .init(name: "答え", description: "答えている")]),
                "c": .score(instructions: "正しそうか", levels: ["違う", "わからない", "合っている"]),
            ]
        )

        #expect(await transport.requests.count == 1)
        let request = try #require(await transport.requests.first)
        #expect(request.url?.absoluteString == "https://example.workers.dev/v1/decide")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token-123")

        let json = try await DecisionFixture.requestJSON(transport)
        #expect(json["model"] as? String == DecisionClient.defaultModel)
        #expect(json["state"] as? [String: String] == ["utterance": "これ見て"])
        let questions = try #require(json["questions"] as? [String: [String: Any]])
        #expect(Set(questions.keys) == ["a", "b", "c"])

        // 真偽は TypeSafe のネイティブ API の型名 noul で送る
        let a = try #require(questions["a"])
        #expect(a["type"] as? String == "noul")
        #expect(a["instructions"] as? String == "先生への発話か")
        #expect(a["criteria"] as? [String: String] == ["true": "先生に話している", "false": "独り言"])

        // 選択肢は名前→説明のオブジェクト
        let b = try #require(questions["b"])
        #expect(b["type"] as? String == "choice")
        #expect(b["criteria"] as? [String: String] == ["質問": "たずねている", "答え": "答えている"])

        // 段階は低い順の配列
        let c = try #require(questions["c"])
        #expect(c["type"] as? String == "score")
        #expect(c["criteria"] as? [String] == ["違う", "わからない", "合っている"])
    }

    @Test func criteriaのない真偽はcriteriaを送らない() async throws {
        let transport = MockTransport(body: #"{"answers":{}}"#)
        _ = await client(transport).decide(state: .text("こんにちは"), questions: ["q": .boolean(instructions: "挨拶か")])
        let json = try await DecisionFixture.requestJSON(transport)
        #expect(json["state"] as? String == "こんにちは")
        let q = try #require((json["questions"] as? [String: [String: Any]])?["q"])
        #expect(q["type"] as? String == "noul")
        #expect(q["criteria"] == nil)
    }

    @Test func 質問がなければ送らない() async {
        let transport = MockTransport(body: "{}")
        #expect(await client(transport).decide(state: .text("x"), questions: [:]) == nil)
        #expect(await transport.requests.isEmpty)
    }

    // MARK: - レスポンスの読み方

    @Test func 型ごとの答えを読む() async throws {
        let body = """
        {"model":"jev-1.14.0","answers":{
          "a":{"type":"noul","noul":0.93},
          "b":{"type":"choice","choice":"答え","confidence":0.7,"probabilities":{"質問":0.15,"答え":0.8,"雑談":0.05}},
          "c":{"type":"score","score":1.7,"confidence":0.9,"legend":{"0":"違う","1":"わからない","2":"合っている"},
               "probabilities":{"0":0.1,"1":0.1,"2":0.8}}
        },"usage":{"input_tokens":120,"output_tokens":12}}
        """
        let transport = MockTransport(body: body)
        let result = try #require(await client(transport).decide(
            state: .text("x"),
            questions: [
                "a": .boolean(instructions: "?"),
                "b": .choice(instructions: "?", options: [
                    .init(name: "質問", description: ""), .init(name: "答え", description: ""), .init(name: "雑談", description: ""),
                ]),
                "c": .score(instructions: "?", levels: ["違う", "わからない", "合っている"]),
            ]
        ))
        #expect(result.model == "jev-1.14.0")
        #expect(result["a"] == .boolean(probability: 0.93))
        #expect(result["b"] == .choice(index: 1, probabilities: [0.15, 0.8, 0.05], confidence: 0.7))
        // 1.7 は四捨五入して段階 2
        #expect(result["c"] == .score(value: 1.7, level: 2, probabilities: [0.1, 0.1, 0.8], confidence: 0.9))
        #expect(result.latency >= .zero)
    }

    @Test func 欠けた答えや知らない型は_その質問だけ読み飛ばす() async throws {
        let body = """
        {"answers":{
          "a":{"type":"noul","noul":0.4},
          "b":{"type":"box","box":{"top":0,"bottom":1,"left":0,"right":1},"confidence":null},
          "c":{"type":"choice","choice":"知らない名前","confidence":0.9,"probabilities":{}}
        }}
        """
        let transport = MockTransport(body: body)
        let result = try #require(await client(transport).decide(
            state: .text("x"),
            questions: [
                "a": .boolean(instructions: "?"),
                "b": .boolean(instructions: "?"),
                "c": .choice(instructions: "?", options: [.init(name: "質問", description: "")]),
                "d": .boolean(instructions: "?"),
            ]
        ))
        #expect(result.answers == ["a": .boolean(probability: 0.4)])
        #expect(result.model == nil)
    }

    @Test func 段階の答えは範囲に収める() async throws {
        let transport = MockTransport(body: #"{"answers":{"c":{"type":"score","score":7.2,"probabilities":{"1":1}}}}"#)
        let result = try #require(await client(transport).decide(
            state: .text("x"), questions: ["c": .score(instructions: "?", levels: ["低", "高"])]
        ))
        #expect(result["c"] == .score(value: 7.2, level: 1, probabilities: [0, 1], confidence: nil))
    }

    // MARK: - 失敗とタイムアウト

    @Test func エラーのステータスならnil() async {
        let transport = MockTransport(status: 502, body: #"{"error":"upstream unreachable"}"#)
        #expect(await client(transport).decide(state: .text("x"), questions: ["a": .boolean(instructions: "?")]) == nil)
    }

    @Test func 読めない本文ならnil() async {
        let transport = MockTransport(body: "not json")
        #expect(await client(transport).decide(state: .text("x"), questions: ["a": .boolean(instructions: "?")]) == nil)
    }

    @Test func 時間内に答えがなければnilを返し_通信をキャンセルする() async {
        let transport = SlowTransport(delay: .seconds(10))
        let clock = ContinuousClock()
        let start = clock.now
        let result = await client(transport, timeout: .milliseconds(50)).decide(state: .text("x"), questions: ["a": .boolean(instructions: "?")])
        #expect(result == nil)
        #expect(clock.now - start < .seconds(1))
        // キャンセルが届くまで少し待つ
        for _ in 0..<50 where !(await transport.wasCancelled) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(await transport.wasCancelled)
    }

    @Test func 呼び出しごとのタイムアウトが既定値より優先される() async {
        let transport = SlowTransport(delay: .milliseconds(300), body: DecisionFixture.noul("a", 0.9))
        let c = client(transport, timeout: .milliseconds(50))
        #expect(await c.decide(state: .text("x"), questions: ["a": .boolean(instructions: "?")]) == nil)
        let result = await c.decide(state: .text("x"), questions: ["a": .boolean(instructions: "?")], timeout: .seconds(5))
        #expect(result?["a"] == .boolean(probability: 0.9))
    }

    @Test func タイムアウトより早く終われば結果を返す() async throws {
        let value = try await DecisionClient.withTimeout(.seconds(5)) { 42 }
        #expect(value == 42)
    }

    @Test func 処理のエラーはそのまま投げる() async {
        await #expect(throws: WorkerError.invalidResponse) {
            _ = try await DecisionClient.withTimeout(.seconds(5)) { () async throws -> Int in throw WorkerError.invalidResponse }
        }
    }

    @Test func 呼び出し側がキャンセルしたら待たずに戻る() async {
        let task = Task {
            try await DecisionClient.withTimeout(.seconds(10)) { () async throws -> Int in
                try await Task.sleep(for: .seconds(10))
                return 1
            }
        }
        try? await Task.sleep(for: .milliseconds(20))
        task.cancel()
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
    }
}
