import Foundation

/// 同期を始めたきっかけ。
enum SyncReason: String, Sendable {
    case appLaunch
    case sessionEnded
    case connectivityRestored
    case manual
    /// セッションを始める直前（親の伝言や、消された記憶を取ってくる）
    case sessionStarting
}

/// 1回の同期の結果。
struct SyncReport: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        /// 最後までできた（4xx で受け付けられなかったものは rejectedSessionIDs にある）。
        case completed
        /// つながらなかった。送れなかったものは pending のまま残り、つながったらまた送る。
        case offline
        /// サーバーの 5xx が続いた、端末の保存に失敗したなど。次のきっかけでまた試す。
        case failed(String)
    }

    var outcome: Outcome = .completed
    var pushedSessionIDs: [String] = []
    /// 4xx で受け付けられなかったセッション（pending のまま。送り直しても同じなので、やり直さない）。
    var rejectedSessionIDs: [String] = []
    var pushedMemoryCategories: [MemoryCategory] = []
    /// 4xx で受け付けられなかった記憶の書き換え。送り直しても同じなので、サーバーの内容で入れ替える。
    var rejectedMemoryCategories: [MemoryCategory] = []
    var pulledMemoryCategories: [MemoryCategory] = []
    var pulledSessionCount = 0
    /// 「伝えた」とサーバーに伝えた親の伝言。
    var acknowledgedMessageIDs: [String] = []
    var pulledMessageCount = 0
}

/// 端末（SyncStore）と Worker の同期 API をつなぐ。
///
/// 順番は「送る → 取ってくる」。
/// 1. pending のセッションを POST /v1/sessions（id で上書きされるので、何度送っても重複しない）
/// 2. 端末で書き換えた記憶のカテゴリを PUT /v1/memory（親がダッシュボードで消した記憶は、サーバーが based_on で照らして取り除く）
/// 3. GET /v1/memory で記憶を取ってきて、カテゴリごとに入れ替える（記憶はサーバーが正）
/// 4. GET /v1/sessions?since=lastPullAt&order=updated&limit=200 でセッションを取ってくる（200 件ならページ送り）
/// 5. 先生が話し終えた親の伝言を POST /v1/messages/:id/delivered で伝え、GET /v1/messages で次の伝言を取ってくる
///
/// 通信エラーと 5xx は指数バックオフでやり直し、4xx はやり直さない。
/// つながらないときは pending のまま残し、つながったら（ConnectivityMonitoring）もう一度同期する。
actor SyncService {
    /// GET /v1/sessions の1ページの件数（サーバーの上限）。
    static let pageSize = 200
    /// ページ送りの上限（同じ updated_at が延々と続くなどで止まらなくならないように）。
    static let maxPages = 50

    private let client: WorkerClient
    private let store: any SyncStore
    private let retry: RetryPolicy
    private let sleep: @Sendable (Duration) async throws -> Void
    private let now: @Sendable () -> Date

    /// 実行中の同期。同時に呼ばれたら、これの終わりを一緒に待つ。
    private var inFlight: Task<SyncReport, Never>?
    /// 実行中に呼ばれたら、終わったあとにもう1回まわす（その間に保存されたセッションを取りこぼさない）。
    private var rerunRequested = false
    private var monitorTask: Task<Void, Never>?
    private(set) var lastReport: SyncReport?

    init(
        client: WorkerClient,
        store: any SyncStore,
        retry: RetryPolicy = .default,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.client = client
        self.store = store
        self.retry = retry
        self.sleep = sleep
        self.now = now
    }

    deinit {
        monitorTask?.cancel()
    }

    /// 今すぐ同期する。セッション終了時と起動時に呼ぶ。実行中なら、それが終わるのを待って同じ結果を返す。
    @discardableResult
    func syncNow(reason: SyncReason) async -> SyncReport {
        if let inFlight {
            rerunRequested = true
            return await inFlight.value
        }
        let task = Task { await self.runUntilSettled() }
        inFlight = task
        return await task.value
    }

    /// つながったら同期する。もう一度呼ぶと前の監視は止める。
    func startMonitoring(_ monitor: any ConnectivityMonitoring) {
        monitorTask?.cancel()
        let events = monitor.connectivityRestored()
        monitorTask = Task { [weak self] in
            for await _ in events {
                guard let self else { return }
                await self.syncNow(reason: .connectivityRestored)
            }
        }
    }

    func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    // MARK: - 中身

    private func runUntilSettled() async -> SyncReport {
        var report: SyncReport
        repeat {
            rerunRequested = false
            report = await performSync()
        } while rerunRequested && report.outcome == .completed
        // ここまで await をはさまないので、次の syncNow は必ず新しく始まる
        rerunRequested = false
        inFlight = nil
        lastReport = report
        return report
    }

    private func performSync() async -> SyncReport {
        var report = SyncReport()
        do {
            try await pushSessions(into: &report)
            try await pushMemories(into: &report)
            try await pullMemories(into: &report)
            try await pullSessions(into: &report)
            try await syncParentMessages(into: &report)
        } catch {
            report.outcome = RetryPolicy.isNetworkError(error) ? .offline : .failed(String(describing: error))
        }
        return report
    }

    private func pushSessions(into report: inout SyncReport) async throws {
        for session in try await store.pendingSessions() {
            let body = try SyncCoding.encoder.encode(session)
            do {
                let data = try await withRetry { try await self.client.postJSON(path: "/v1/sessions", body: body) }
                _ = try SyncCoding.decoder.decode(SessionResponse.self, from: data)
            } catch WorkerError.http(let status, _) where (400..<500).contains(status) {
                report.rejectedSessionIDs.append(session.id)
                continue
            }
            // 1件ずつ印を付ける（途中で切れても、送れた分は送り直さない）
            try await store.markSynced(ids: [session.id], at: now())
            report.pushedSessionIDs.append(session.id)
        }
    }

    private func pushMemories(into report: inout SyncReport) async throws {
        let pending = try await store.pendingMemoryCategories()
        for category in MemoryCategory.allCases where pending.contains(category) {
            // based_on より後に親が消した記憶は、サーバーが取り除いて返す（未送信の変更で復活させない。#160）
            let request = MemoryPutRequest(
                category: category,
                items: try await store.localMemories(category: category),
                basedOn: try await store.memoryBase(category: category)
            )
            let body = try SyncCoding.encoder.encode(request)
            let data: Data
            do {
                data = try await withRetry { try await self.client.putJSON(path: "/v1/memory", body: body) }
            } catch WorkerError.http(let status, _) where (400..<500).contains(status) {
                report.rejectedMemoryCategories.append(category)
                continue
            }
            let response = try SyncCoding.decoder.decode(MemoryListResponse.self, from: data)
            try await store.replaceMemories(category: category, items: response.memories)
            if let serverTime = response.serverTime { try await store.setMemoryBase(serverTime, category: category) }
            report.pushedMemoryCategories.append(category)
        }
    }

    private func pullMemories(into report: inout SyncReport) async throws {
        let data = try await withRetry { try await self.client.getJSON(path: "/v1/memory") }
        let response = try SyncCoding.decoder.decode(MemoryListResponse.self, from: data)
        // 同期の途中で書き換えたものは消さない（次の同期で送る）。4xx で断られたものはサーバーの内容に戻す
        let pending = try await store.pendingMemoryCategories().subtracting(report.rejectedMemoryCategories)
        for category in MemoryCategory.allCases where !pending.contains(category) {
            // サーバーで空になったカテゴリも空に入れ替える
            try await store.replaceMemories(category: category, items: response.memories.filter { $0.category == category })
            // 揃えたカテゴリだけ進める。端末で書き換え中のカテゴリは古い内容のままなので、親が消したものを取り除いてもらう
            if let serverTime = response.serverTime { try await store.setMemoryBase(serverTime, category: category) }
            report.pulledMemoryCategories.append(category)
        }
    }

    private func pullSessions(into report: inout SyncReport) async throws {
        var since = await store.lastPullAt
        var firstServerTime: Date?
        for _ in 0..<Self.maxPages {
            var query = [
                URLQueryItem(name: "order", value: "updated"),
                URLQueryItem(name: "limit", value: String(Self.pageSize)),
            ]
            if let since { query.append(URLQueryItem(name: "since", value: SyncCoding.formatDate(since))) }
            let items = query
            let data = try await withRetry { try await self.client.getJSON(path: "/v1/sessions", query: items) }
            let page = try SyncCoding.decoder.decode(SessionListResponse.self, from: data)
            firstServerTime = firstServerTime ?? page.serverTime
            try await store.upsertRemoteSessions(page.sessions)
            report.pulledSessionCount += page.sessions.count

            // 200 件未満なら最後のページ。続きは最後の updated_at から（境目の重複は id で上書きされる）
            guard page.sessions.count >= Self.pageSize, let last = page.sessions.last?.updatedAt, last != since else { break }
            since = last
        }
        // 最初のページのサーバー時刻を次の since にする（ページ送り中に保存されたものも次回取れる）
        if let firstServerTime { try await store.setLastPullAt(firstServerTime) }
    }

    private func syncParentMessages(into report: inout SyncReport) async throws {
        for (id, toldAt) in try await store.toldParentMessages().sorted(by: { $0.value < $1.value }) {
            let body = try SyncCoding.encoder.encode(ParentMessageDeliveredRequest(deliveredAt: toldAt))
            do {
                _ = try await withRetry { try await self.client.postJSON(path: "/v1/messages/\(id)/delivered", body: body) }
            } catch WorkerError.http(let status, _) where (400..<500).contains(status) {
                // もうサーバーにない。送り直しても同じなので、端末からも消す
            }
            try await store.forgetParentMessage(id: id)
            report.acknowledgedMessageIDs.append(id)
        }
        let data: Data
        do {
            data = try await withRetry { try await self.client.getJSON(path: "/v1/messages") }
        } catch WorkerError.http(let status, _) where (400..<500).contains(status) {
            // 受け付けられないときも、ほかの同期は成功のままにする。今ある伝言は残す
            return
        }
        let response = try SyncCoding.decoder.decode(ParentMessageListResponse.self, from: data)
        try await store.replaceParentMessages(response.messages)
        report.pulledMessageCount = response.messages.count
    }

    private func withRetry<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        try await retry.run(sleep: sleep, operation)
    }
}
