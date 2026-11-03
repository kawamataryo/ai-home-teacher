import Foundation
@testable import HomeTeacher

/// 答えるまでに時間がかかるモック（タイムアウトを試す）。キャンセルされたら sleep が throw する。
actor SlowTransport: HTTPTransport {
    let delay: Duration
    let body: String
    private(set) var requestCount = 0
    private(set) var wasCancelled = false

    init(delay: Duration = .seconds(10), body: String = #"{"answers":{}}"#) {
        self.delay = delay
        self.body = body
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestCount += 1
        do {
            try await Task.sleep(for: delay)
        } catch {
            wasCancelled = true
            throw error
        }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    func lines(for request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse) {
        throw WorkerError.invalidResponse
    }
}

enum DecisionFixture {
    static func worker(_ transport: any HTTPTransport) -> WorkerClient {
        WorkerClient(baseURL: URL(string: "https://example.workers.dev")!, familyToken: "token-123", transport: transport)
    }

    static func decisions(_ transport: any HTTPTransport, timeout: Duration = .milliseconds(800)) -> TeacherDecisions {
        TeacherDecisions(client: DecisionClient(worker: worker(transport), timeout: timeout))
    }

    /// 真偽の答え 1 つだけのレスポンス
    static func noul(_ key: String, _ p: Double) -> String {
        #"{"model":"jev-1.14.0","answers":{"\#(key)":{"type":"noul","noul":\#(p)}},"usage":{"input_tokens":120,"output_tokens":3}}"#
    }

    /// 発話の判断をまとめて聞くキャッシュ
    @MainActor
    static func cache(_ transport: any HTTPTransport, timeout: Duration = .milliseconds(800)) -> UtteranceDecisionCache {
        UtteranceDecisionCache(decisions: decisions(transport, timeout: timeout), timeout: timeout)
    }

    /// 真偽の答えをいくつも入れたレスポンス
    static func nouls(_ answers: [String: Double]) -> String {
        let items = answers.keys.sorted().map { #""\#($0)":{"type":"noul","noul":\#(answers[$0]!)}"# }
        return #"{"model":"jev-1.14.0","answers":{\#(items.joined(separator: ","))},"usage":{"input_tokens":200,"output_tokens":6}}"#
    }

    static func choice(_ key: String, _ choice: String, probabilities: [String: Double]) -> String {
        let probs = SSEFixture.json(probabilities)
        return #"{"model":"jev-1.14.0","answers":{"\#(key)":{"type":"choice","choice":"\#(choice)","confidence":0.8,"probabilities":\#(probs)}},"usage":{"input_tokens":120,"output_tokens":3}}"#
    }

    /// 送られた本文を JSON のオブジェクトとして読む
    static func requestJSON(_ transport: MockTransport, at index: Int = 0) async throws -> [String: Any] {
        let bodies = await transport.requestBodies()
        let object = try JSONSerialization.jsonObject(with: bodies[index])
        return object as? [String: Any] ?? [:]
    }
}

/// 中の判定に任せつつ、答えが出たら知らせる（Jev の返事を待ってから時計を進めるため）。
@MainActor
final class ObservedEndOfUtteranceDecider: EndOfUtteranceDecider {
    let inner: any EndOfUtteranceDecider
    private(set) var results: [Bool] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ inner: any EndOfUtteranceDecider) { self.inner = inner }

    func isUtteranceComplete(_ transcript: String) async -> Bool {
        let result = await inner.isUtteranceComplete(transcript)
        results.append(result)
        let w = waiters
        waiters = []
        w.forEach { $0.resume() }
        return result
    }

    func waitUntilAnswered(count: Int = 1) async {
        while results.count < count {
            await withCheckedContinuation { waiters.append($0) }
        }
    }
}
