import Foundation

/// HTTP の送受信を差し替えるための口。テストではモックを渡す。
protocol HTTPTransport: Sendable {
    /// 本文をまとめて受け取る。
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// 本文を1行ずつ受け取る（SSE 用）。空行は届かないことがある前提で扱う。
    func lines(for request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse)
}

/// URLSession を使う本番用の実装。
struct URLSessionTransport: HTTPTransport {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WorkerError.invalidResponse }
        return (data, http)
    }

    func lines(for request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw WorkerError.invalidResponse }
        let stream = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // 受け手が止めたら（割り込みなど）読み込みも止める
            continuation.onTermination = { _ in task.cancel() }
        }
        return (stream, http)
    }
}

enum WorkerError: Error, Equatable {
    /// 200 番台以外。Worker のエラーは JSON（例: {"error":"unauthorized"}）で返る。
    case http(status: Int, body: String)
    case invalidResponse
}

/// Cloudflare Worker を呼ぶ共通クライアント。家族トークンを付けて POST する。
/// エンドポイント（/v1/claude, /v1/tts, /v1/decide, /v1/sessions …）ごとの組み立ては呼び出し側で行う。
struct WorkerClient: Sendable {
    let baseURL: URL
    let familyToken: String
    let transport: any HTTPTransport

    init(baseURL: URL, familyToken: String, transport: any HTTPTransport = URLSessionTransport()) {
        self.baseURL = baseURL
        self.familyToken = familyToken
        self.transport = transport
    }

    init(config: AppConfig, transport: any HTTPTransport = URLSessionTransport()) {
        self.init(baseURL: config.workerBaseURL, familyToken: config.familyToken, transport: transport)
    }

    /// `path` は "/v1/claude" のように先頭の / 付きで渡す。
    func makeRequest(path: String, body: Data, accept: String = "application/json") -> URLRequest {
        var request = URLRequest(url: url(for: path))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(familyToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// JSON を POST して本文を返す。
    func postJSON(path: String, body: Data) async throws -> Data {
        let (data, response) = try await transport.data(for: makeRequest(path: path, body: body))
        guard (200..<300).contains(response.statusCode) else {
            throw WorkerError.http(status: response.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        return data
    }

    func postJSON(path: String, body: some Encodable) async throws -> Data {
        try await postJSON(path: path, body: Self.encoder.encode(body))
    }

    /// JSON を POST して、本文を1行ずつ返す（SSE 用）。エラーのステータスなら本文を読んで投げる。
    func streamLines(path: String, body: Data) async throws -> AsyncThrowingStream<String, Error> {
        let request = makeRequest(path: path, body: body, accept: "text/event-stream")
        let (lines, response) = try await transport.lines(for: request)
        guard (200..<300).contains(response.statusCode) else {
            var text: [String] = []
            for try await line in lines { text.append(line) }
            throw WorkerError.http(status: response.statusCode, body: text.joined(separator: "\n"))
        }
        return lines
    }

    func streamLines(path: String, body: some Encodable) async throws -> AsyncThrowingStream<String, Error> {
        try await streamLines(path: path, body: Self.encoder.encode(body))
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private func url(for path: String) -> URL {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return baseURL.appending(path: trimmed)
    }
}
