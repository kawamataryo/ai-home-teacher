import Foundation
import UIKit
@testable import HomeTeacher

/// パス（と、まとめて受け取るか 1 行ずつか）ごとに応答を返すモック。
/// 会話（`/v1/claude` を 1 行ずつ）とふり返り（`/v1/claude` をまとめて）が同じパスを使うので、受け取り方でも分ける。
/// 用意がない呼び出しには 500 を返す（Jev の `/v1/decide` は規則ベースに切り替わる）。
actor RoutingTransport: HTTPTransport {
    enum Kind: Hashable, Sendable {
        case data
        case lines
    }

    enum Reply: Sendable {
        case body(status: Int, String)
        /// 返さずに待ち続ける（通信中を再現する）
        case hang
        /// 途中まで返して、そのあと待ち続ける（ストリームの途中で割り込まれるところを再現する）
        case partial(String)
    }

    private var routes: [String: [Reply]] = [:]
    private(set) var requests: [(kind: Kind, request: URLRequest)] = []
    private var hanging: [AsyncThrowingStream<String, Error>.Continuation] = []

    func enqueue(_ kind: Kind, _ path: String, _ replies: [Reply]) {
        routes[key(kind, path), default: []] += replies
    }

    func enqueue(_ kind: Kind, _ path: String, body: String) {
        enqueue(kind, path, [.body(status: 200, body)])
    }

    /// 送られた本文を、受け取り方とパスで絞って返す
    func bodyData(_ kind: Kind, _ path: String) -> [Data] {
        requests
            .filter { $0.kind == kind && $0.request.url?.path() == path }
            .compactMap { $0.request.httpBody }
    }

    func count(_ kind: Kind, _ path: String) -> Int {
        requests.filter { $0.kind == kind && $0.request.url?.path() == path }.count
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append((.data, request))
        switch next(.data, request) {
        case .body(let status, let body):
            return (Data(body.utf8), http(request, status))
        case .hang, .partial:
            try await Task.sleep(for: .seconds(3600))
            throw CancellationError()
        }
    }

    func lines(for request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse) {
        requests.append((.lines, request))
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        switch next(.lines, request) {
        case .body(let status, let body):
            for line in body.split(separator: "\n", omittingEmptySubsequences: true) { continuation.yield(String(line)) }
            continuation.finish()
            return (stream, http(request, status))
        case .hang:
            hanging.append(continuation)
            return (stream, http(request, 200))
        case .partial(let body):
            for line in body.split(separator: "\n", omittingEmptySubsequences: true) { continuation.yield(String(line)) }
            hanging.append(continuation)
            return (stream, http(request, 200))
        }
    }

    private func next(_ kind: Kind, _ request: URLRequest) -> Reply {
        let k = key(kind, request.url?.path() ?? "")
        guard var queue = routes[k], !queue.isEmpty else { return .body(status: 500, #"{"error":"no route"}"#) }
        let reply = queue.removeFirst()
        routes[k] = queue
        return reply
    }

    private func key(_ kind: Kind, _ path: String) -> String { "\(kind):\(path)" }

    private func http(_ request: URLRequest, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }
}

/// 先生の声のモック。`holdsPlayback` のときは `finishCurrent()` か `stop()` まで 1 文が終わらない
@MainActor
final class MockTeacherVoice: TeacherSpeaking {
    var holdsPlayback = false
    /// `stop()` が返す「何文字目まで話したか」
    var playedCharactersOnStop = 0
    private(set) var spoken: [String] = []
    private(set) var stopCount = 0
    private var playing: CheckedContinuation<Void, Never>?

    func speak(_ text: String) async {
        spoken.append(text)
        guard holdsPlayback else { return }
        await withCheckedContinuation { playing = $0 }
    }

    func finishCurrent() {
        playing?.resume()
        playing = nil
    }

    @discardableResult
    func stop() -> Int {
        stopCount += 1
        let wasPlaying = playing != nil
        finishCurrent()
        return wasPlaying ? playedCharactersOnStop : 0
    }
}

/// 同期のモック。呼ばれたきっかけを残す
actor MockSync: SessionSyncing {
    private(set) var reasons: [SyncReason] = []

    func syncNow(reason: SyncReason) async -> SyncReport {
        reasons.append(reason)
        return SyncReport()
    }
}

/// 条件を満たすまで待つ（MainActor のタスクを進める）。時間切れなら false
@MainActor
func eventually(timeout: Duration = .seconds(3), _ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

/// まとめ役とモック一式
@MainActor
final class SessionHarness {
    let transport = RoutingTransport()
    let input = ScriptedSpeechInput()
    let voice = MockTeacherVoice()
    let clock = ManualClock()
    let sync = MockSync()
    let store: MemorySyncStore
    let coordinator: StudySessionCoordinator

    init(
        settings: StudySessionCoordinator.Settings = .init(),
        preferences: SessionPreferences? = nil,
        camera: (any PhotoCapturing)? = nil,
        now: Date = Date(timeIntervalSince1970: 1_793_000_000)
    ) throws {
        store = MemorySyncStore(base: try SwiftDataMemoryStore.inMemory(), stateStorage: InMemorySyncStateStorage())
        let client = WorkerClient(baseURL: URL(string: "https://example.workers.dev")!, familyToken: "t", transport: transport)
        coordinator = StudySessionCoordinator(dependencies: .init(
            client: client, input: input, voice: voice, store: store, sync: sync, clock: clock,
            preferences: preferences, camera: camera, countdown: InstantCountdown(), now: { now }
        ))
        coordinator.settings = settings
        coordinator.listen()
    }

    /// 会話の返事（SSE）を 1 つ用意する
    func enqueueReply(_ deltas: [String]) async {
        await transport.enqueue(.lines, "/v1/claude", body: SSEFixture.textStream(deltas))
    }

    /// 子どもが話して、無音で区切られるところまで
    func say(_ text: String) async {
        input.say(text)
        // 入力の出来事がまとめ役を通ってコントローラに届くのを待つ
        _ = await eventually { self.coordinator.controller?.state == .listening }
        // 話し終わり（voiceEnded）が届いて無音のタイマーが動くまで、少しずつ時間を進める
        for _ in 0..<100 where coordinator.controller?.state == .listening {
            clock.advance(by: coordinator.settings.conversation.endOfUtteranceSilence)
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// 送った本文（JSON）
    func bodies(_ kind: RoutingTransport.Kind, _ path: String) async -> [[String: Any]] {
        await transport.bodyData(kind, path).compactMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }

    /// 会話の Claude に送った本文
    func conversationRequests() async -> [[String: Any]] {
        await bodies(.lines, "/v1/claude")
    }
}

extension SSEFixture {
    /// 文字を流している途中（content_block_stop の前）までのストリーム
    static func partialTextStream(_ deltas: [String]) -> String {
        let full = textStream(deltas)
        guard let range = full.range(of: "event: content_block_stop") else { return full }
        return String(full[..<range.lowerBound])
    }
}

extension SessionHarness {
    /// 最後の先生の発言（履歴）
    func lastAssistantText() async -> String? {
        await coordinator.brain?.history.lastAssistantText
    }
}

/// 撮影のモック。決まった大きさの画像を返す
@MainActor
final class MockCamera: PhotoCapturing {
    var isAvailable = true
    var fails = false
    let size: CGSize
    private(set) var preparedPositions: [CameraPosition] = []
    private(set) var captureCount = 0

    init(size: CGSize = CGSize(width: 4032, height: 3024)) {
        self.size = size
    }

    func prepare(position: CameraPosition) async throws {
        preparedPositions.append(position)
    }

    func capture() async throws -> UIImage {
        captureCount += 1
        if fails { throw CameraError.captureFailed }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }
}

/// 待たずに数えるカウントダウン
@MainActor
final class InstantCountdown: CountdownPlaying {
    private(set) var ticks: [Int] = []

    func countdown(from start: Int, onTick: @escaping @MainActor (Int) -> Void) async {
        for n in stride(from: start, through: 1, by: -1) {
            ticks.append(n)
            onTick(n)
        }
    }
}
