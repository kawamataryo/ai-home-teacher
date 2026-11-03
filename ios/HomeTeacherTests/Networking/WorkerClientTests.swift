import Foundation
import Testing
@testable import HomeTeacher

struct WorkerClientTests {
    private func client(_ transport: MockTransport) -> WorkerClient {
        WorkerClient(baseURL: URL(string: "https://example.workers.dev")!, familyToken: "token-123", transport: transport)
    }

    @Test func 家族トークンとJSONのヘッダーを付けてPOSTする() async throws {
        let transport = MockTransport(body: #"{"ok":true}"#)
        let data = try await client(transport).postJSON(path: "/v1/decide", body: Data("{}".utf8))
        #expect(String(decoding: data, as: UTF8.self) == #"{"ok":true}"#)

        let request = try #require(await transport.requests.first)
        #expect(request.url?.absoluteString == "https://example.workers.dev/v1/decide")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token-123")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test func エラーのステータスなら本文を付けて投げる() async {
        let transport = MockTransport(status: 401, body: #"{"error":"unauthorized"}"#)
        await #expect(throws: WorkerError.http(status: 401, body: #"{"error":"unauthorized"}"#)) {
            _ = try await client(transport).postJSON(path: "/v1/claude", body: Data("{}".utf8))
        }
    }

    @Test func ストリームを1行ずつ返す() async throws {
        let transport = MockTransport(body: "data: a\n\ndata: b\n")
        var lines: [String] = []
        for try await line in try await client(transport).streamLines(path: "/v1/claude", body: Data("{}".utf8)) {
            lines.append(line)
        }
        #expect(lines == ["data: a", "data: b"])
        let request = try #require(await transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "Accept") == "text/event-stream")
    }

    @Test func ストリームでもエラーのステータスなら投げる() async {
        let transport = MockTransport(status: 400, body: #"{"error":"model not allowed"}"#)
        await #expect(throws: WorkerError.http(status: 400, body: #"{"error":"model not allowed"}"#)) {
            _ = try await client(transport).streamLines(path: "/v1/claude", body: Data("{}".utf8))
        }
    }
}
