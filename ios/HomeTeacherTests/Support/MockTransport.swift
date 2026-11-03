import Foundation
@testable import HomeTeacher

/// 決まった応答を返し、送られたリクエストを記録するモック。
actor MockTransport: HTTPTransport {
    struct Response: Sendable {
        var status: Int = 200
        var body: String
        /// あれば応答の代わりにこのエラーを投げる（オフラインなど）。
        var error: URLError.Code?
        /// あれば `body` の代わりにこのバイト列を返す（音声など、文字にできない本文）。
        var bytes: Data?

        /// 通信エラー（URLError）を投げる応答。
        static func failure(_ code: URLError.Code) -> Response {
            Response(status: 0, body: "", error: code)
        }
    }

    private var responses: [Response]
    private(set) var requests: [URLRequest] = []

    init(responses: [Response]) {
        self.responses = responses
    }

    init(status: Int = 200, body: String) {
        self.init(responses: [Response(status: status, body: body)])
    }

    /// 応答をあとから足す。
    func enqueue(_ more: [Response]) {
        responses += more
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let response = next(for: request)
        if let code = response.error { throw URLError(code) }
        return (response.bytes ?? Data(response.body.utf8), http(request, response.status))
    }

    /// URLSession の `lines` と同じく、空行は落として1行ずつ流す。
    func lines(for request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse) {
        let response = next(for: request)
        if let code = response.error { throw URLError(code) }
        let lines = response.body.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let stream = AsyncThrowingStream<String, Error> { continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }
        return (stream, http(request, response.status))
    }

    /// 送られた本文。
    func requestBodies() -> [Data] {
        requests.compactMap(\.httpBody)
    }

    private func next(for request: URLRequest) -> Response {
        requests.append(request)
        return responses.isEmpty ? Response(status: 500, body: "no more responses") : responses.removeFirst()
    }

    private func http(_ request: URLRequest, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }
}

/// SSE のフィクスチャを組み立てる。
enum SSEFixture {
    static func textStream(_ deltas: [String], stopReason: String = "end_turn") -> String {
        var events = [
            #"event: message_start"#,
            #"data: {"type":"message_start","message":{"id":"msg_1","type":"message","role":"assistant","content":[],"model":"claude-haiku-5-5"}}"#,
            "",
            #"event: content_block_start"#,
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            "",
            #"event: ping"#,
            #"data: {"type":"ping"}"#,
            "",
        ]
        for delta in deltas {
            events += ["event: content_block_delta", "data: " + json([
                "type": "content_block_delta", "index": 0,
                "delta": ["type": "text_delta", "text": delta],
            ]), ""]
        }
        events += [
            #"event: content_block_stop"#,
            #"data: {"type":"content_block_stop","index":0}"#,
            "",
            #"event: message_delta"#,
            "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"\(stopReason)\",\"stop_sequence\":null},\"usage\":{\"output_tokens\":10}}",
            "",
            #"event: message_stop"#,
            #"data: {"type":"message_stop"}"#,
            "",
        ]
        return events.joined(separator: "\n")
    }

    /// 言葉で返事をしてから（`text` が空なら言葉なしで）flag_for_parent を呼ぶストリーム。
    static func toolStream(text: String, toolID: String = "toolu_1", name: String = "flag_for_parent", inputJSON: String) -> String {
        var events = [#"data: {"type":"message_start","message":{"id":"msg_2","role":"assistant","content":[]}}"#]
        var index = 0
        if !text.isEmpty {
            events += [
                #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
                "data: " + json(["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": text]]),
                #"data: {"type":"content_block_stop","index":0}"#,
            ]
            index = 1
        }
        // partial_json は2つに分けて送る
        let mid = inputJSON.index(inputJSON.startIndex, offsetBy: inputJSON.count / 2)
        events += [
            "data: " + json(["type": "content_block_start", "index": index,
                             "content_block": ["type": "tool_use", "id": toolID, "name": name, "input": [String: Any]()]]),
            "data: " + json(["type": "content_block_delta", "index": index,
                             "delta": ["type": "input_json_delta", "partial_json": String(inputJSON[..<mid])]]),
            "data: " + json(["type": "content_block_delta", "index": index,
                             "delta": ["type": "input_json_delta", "partial_json": String(inputJSON[mid...])]]),
            "data: {\"type\":\"content_block_stop\",\"index\":\(index)}",
            #"data: {"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#,
            #"data: {"type":"message_stop"}"#,
        ]
        return events.joined(separator: "\n\n")
    }

    static func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}

/// 決まった行を流したあと、終わらずに待ち続けるモック（通信中の割り込みを試す）。
actor HangingTransport: HTTPTransport {
    private let lines: [String]
    private(set) var requestCount = 0
    /// ストリームが勝手に終わらないように持っておく。
    private var continuations: [AsyncThrowingStream<String, Error>.Continuation] = []

    init(lines: [String]) {
        self.lines = lines
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw WorkerError.invalidResponse
    }

    func lines(for request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse) {
        requestCount += 1
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        for line in lines { continuation.yield(line) }
        continuations.append(continuation)
        return (stream, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
