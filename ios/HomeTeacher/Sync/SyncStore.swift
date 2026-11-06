import Foundation

/// 同期が読み書きする端末内の保存先。アプリの永続化（SwiftData, #25）がこれを実装する。
/// SwiftData の ModelActor や @MainActor の型からも実装できるように、すべて async にしている。
protocol SyncStore: Sendable {
    /// まだサーバーに送れていない（終わった）セッション。
    func pendingSessions() async throws -> [SessionDTO]
    /// 送れたセッションに印を付ける。次からは pendingSessions に出さない。
    func markSynced(ids: [String], at date: Date) async throws
    /// サーバーから取ってきたセッションを id で上書き保存する。
    /// まだ送れていない（pending の）セッションは端末側が新しいので、上書きしないこと。
    func upsertRemoteSessions(_ sessions: [SessionDTO]) async throws

    /// 端末で書き換えて、まだサーバーに送れていない記憶のカテゴリ。
    func pendingMemoryCategories() async throws -> Set<MemoryCategory>
    /// そのカテゴリの記憶をサーバーの内容でまるごと入れ替える（記憶はサーバーが正）。
    /// 入れ替えたカテゴリは pending でなくなる。
    func replaceMemories(category: MemoryCategory, items: [MemoryDTO]) async throws
    /// 端末にあるそのカテゴリの記憶（PUT で送る内容）。
    func localMemories(category: MemoryCategory) async throws -> [MemoryItemDTO]

    /// サーバーのまだ伝えていない伝言で入れ替える。先生が話し終えたもの（told）は入れない。
    func replaceParentMessages(_ messages: [ParentMessage]) async throws
    /// 先生が話し終えて、まだサーバーに伝えていない伝言（id → 話し終えた時刻）。
    func toldParentMessages() async throws -> [String: Date]
    /// サーバーに伝えた（または、サーバーにもうない）。端末から消す。
    func forgetParentMessage(id: String) async throws

    /// 最後にセッションを取ってきたときのサーバー時刻（次の since）。
    var lastPullAt: Date? { get async }
    func setLastPullAt(_ date: Date) async throws
}

/// 親の伝言の受け箱（#159）。先生のまとめ役が読む。
protocol ParentMessageInbox: Sendable {
    /// 次に伝える伝言（いちばん古いもの）。なければ nil。
    func nextParentMessage() async -> ParentMessage?
    /// 先生が話し終えたら呼ぶ。次のセッションでは伝えない。サーバーには次の同期で伝える。
    func markParentMessageTold(id: String, at date: Date) async
}

/// メモリ上だけの SyncStore。テストと、永続化がつながるまでの仮置きに使う。
actor InMemorySyncStore: SyncStore {
    /// 端末にあるセッション（id → 中身）。
    private(set) var sessions: [String: SessionDTO] = [:]
    /// 送れた時刻（id → 時刻）。ないものが pending。
    private(set) var syncedAt: [String: Date] = [:]
    /// サーバーから入れ替えた記憶。
    private(set) var memories: [MemoryCategory: [MemoryDTO]] = [:]
    /// 端末で書き換えて、まだ送れていない記憶。
    private(set) var localEdits: [MemoryCategory: [MemoryItemDTO]] = [:]
    private var pullAt: Date?
    private(set) var parentMessages: [ParentMessage] = []
    private(set) var toldMessages: [String: Date] = [:]

    init(sessions: [SessionDTO] = [], memories: [MemoryCategory: [MemoryDTO]] = [:], lastPullAt: Date? = nil) {
        for session in sessions { self.sessions[session.id] = session }
        self.memories = memories
        self.pullAt = lastPullAt
    }

    /// 終わったセッションを保存する（pending になる）。
    func save(_ session: SessionDTO) {
        sessions[session.id] = session
        syncedAt[session.id] = nil
    }

    /// 端末で記憶を書き換える（pending になる）。
    func setLocalMemories(_ contents: [String], category: MemoryCategory) {
        localEdits[category] = contents.map(MemoryItemDTO.init(content:))
    }

    func pendingSessions() -> [SessionDTO] {
        sessions.values.filter { syncedAt[$0.id] == nil }.sorted { $0.startedAt < $1.startedAt }
    }

    func markSynced(ids: [String], at date: Date) {
        for id in ids where sessions[id] != nil { syncedAt[id] = date }
    }

    func upsertRemoteSessions(_ remote: [SessionDTO]) {
        for session in remote {
            if sessions[session.id] != nil, syncedAt[session.id] == nil { continue }
            sessions[session.id] = session
            syncedAt[session.id] = session.updatedAt ?? syncedAt[session.id] ?? .distantPast
        }
    }

    func pendingMemoryCategories() -> Set<MemoryCategory> {
        Set(localEdits.keys)
    }

    func replaceMemories(category: MemoryCategory, items: [MemoryDTO]) {
        memories[category] = items
        localEdits[category] = nil
    }

    func localMemories(category: MemoryCategory) -> [MemoryItemDTO] {
        localEdits[category] ?? (memories[category] ?? []).map { MemoryItemDTO(content: $0.content) }
    }

    func replaceParentMessages(_ messages: [ParentMessage]) {
        parentMessages = messages.filter { toldMessages[$0.id] == nil }
    }

    func toldParentMessages() -> [String: Date] {
        toldMessages
    }

    func forgetParentMessage(id: String) {
        toldMessages[id] = nil
        parentMessages.removeAll { $0.id == id }
    }

    func markTold(id: String, at date: Date) {
        toldMessages[id] = date
        parentMessages.removeAll { $0.id == id }
    }

    var lastPullAt: Date? { pullAt }

    func setLastPullAt(_ date: Date) {
        pullAt = date
    }
}
