import Foundation
import os

/// 同期の状態（次の since と、まだ送れていない記憶のカテゴリ）。MemoryStore には持たせず、別に保存する。
struct SyncState: Codable, Equatable, Sendable {
    var lastPullAt: Date?
    var dirtyMemoryCategories: Set<MemoryCategory> = []
}

/// SyncState の保存先。
protocol SyncStateStorage: Sendable {
    func load() -> SyncState
    func save(_ state: SyncState)
}

/// UserDefaults に JSON で保存する本番用の実装。
struct UserDefaultsSyncStateStorage: SyncStateStorage {
    var suiteName: String?
    var key = "HomeTeacher.SyncState"

    func load() -> SyncState {
        guard let data = defaults.data(forKey: key),
              let state = try? JSONDecoder().decode(SyncState.self, from: data) else { return SyncState() }
        return state
    }

    func save(_ state: SyncState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: key)
    }

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }
}

/// メモリ上だけの実装（テスト用）。
final class InMemorySyncStateStorage: SyncStateStorage {
    private let state: OSAllocatedUnfairLock<SyncState>

    init(_ initial: SyncState = SyncState()) {
        state = OSAllocatedUnfairLock(initialState: initial)
    }

    func load() -> SyncState { state.withLock { $0 } }
    func save(_ newValue: SyncState) { state.withLock { $0 = newValue } }
}

/// #25 の MemoryStore（SwiftDataMemoryStore）を同期につなぐアダプタ。
///
/// SyncStore として SyncService に渡し、MemoryStore としてアプリ（SessionReflector など）にも渡す。
/// アプリが記憶を書き換えたら（applyMemoryUpdates / replaceMemories(category:with:)）そのカテゴリを
/// 「まだ送れていない」にして、次の同期で PUT /v1/memory する。値型（〜Record）だけでやりとりする。
actor MemorySyncStore: SyncStore, MemoryStore {
    private let base: any MemoryStore
    private let stateStorage: any SyncStateStorage
    private var state: SyncState

    init(base: any MemoryStore, stateStorage: any SyncStateStorage = UserDefaultsSyncStateStorage()) {
        self.base = base
        self.stateStorage = stateStorage
        self.state = stateStorage.load()
    }

    // MARK: - SyncStore

    func pendingSessions() async throws -> [SessionDTO] {
        try await base.unsyncedSessions().map(SessionDTO.init(record:))
    }

    func markSynced(ids: [String], at date: Date) async throws {
        for id in ids { try await base.markSynced(sessionID: id, at: date) }
    }

    func upsertRemoteSessions(_ sessions: [SessionDTO]) async throws {
        // まだ送れていない端末のセッションは端末のほうが新しいので上書きしない
        let pending = Set(try await base.unsyncedSessions().map(\.id))
        for session in sessions where !pending.contains(session.id) {
            try await base.saveSession(StudySessionRecord(dto: session, syncedAt: session.updatedAt ?? Date()))
        }
    }

    func pendingMemoryCategories() -> Set<MemoryCategory> {
        state.dirtyMemoryCategories
    }

    func replaceMemories(category: MemoryCategory, items: [MemoryDTO]) async throws {
        let records = items.filter { $0.category == category }
            .map { MemoryRecord(category: category, content: $0.content, updatedAt: $0.updatedAt) }
        try await base.replaceMemories(category: category, with: records)
        update { $0.dirtyMemoryCategories.remove(category) }
    }

    func localMemories(category: MemoryCategory) async throws -> [MemoryItemDTO] {
        try await base.memories(category: category).map { MemoryItemDTO(content: $0.content) }
    }

    var lastPullAt: Date? { state.lastPullAt }

    func setLastPullAt(_ date: Date) {
        update { $0.lastPullAt = date }
    }

    // MARK: - MemoryStore（そのまま渡す。記憶を書き換えたら送る印を付ける）

    func saveSession(_ session: StudySessionRecord) async throws {
        try await base.saveSession(session)
    }

    func recentSessions(limit: Int) async throws -> [StudySessionRecord] {
        try await base.recentSessions(limit: limit)
    }

    func unsyncedSessions() async throws -> [StudySessionRecord] {
        try await base.unsyncedSessions()
    }

    func markSynced(sessionID: String, at date: Date) async throws {
        try await base.markSynced(sessionID: sessionID, at: date)
    }

    func memories(category: MemoryCategory?) async throws -> [MemoryRecord] {
        try await base.memories(category: category)
    }

    func replaceMemories(category: MemoryCategory, with items: [MemoryRecord]) async throws {
        try await base.replaceMemories(category: category, with: items)
        update { $0.dirtyMemoryCategories.insert(category) }
    }

    func applyMemoryUpdates(_ updates: MemoryUpdates, now: Date) async throws {
        try await base.applyMemoryUpdates(updates, now: now)
        let touched = updates.changes.filter { !$0.value.add.isEmpty || !$0.value.remove.isEmpty }.keys
        update { $0.dirtyMemoryCategories.formUnion(touched) }
    }

    private func update(_ change: (inout SyncState) -> Void) {
        change(&state)
        stateStorage.save(state)
    }
}

// MARK: - 値型の変換

extension SessionDTO {
    init(record: StudySessionRecord) {
        self.init(
            id: record.id, startedAt: record.startedAt, endedAt: record.endedAt, focusMinutes: record.focusMinutes,
            summary: record.summary, teacherNote: record.teacherNote, parentPrompt: record.parentPrompt, flags: record.flags,
            problems: record.problems.map {
                ProblemDTO(kind: $0.kind, summary: $0.summary, solvedBySelf: $0.solvedBySelf,
                           hintLevelReached: $0.hintLevelReached, createdAt: $0.createdAt)
            }
        )
    }
}

extension StudySessionRecord {
    /// サーバーから取ってきたセッション。送り直さないように syncedAt を入れる。
    init(dto: SessionDTO, syncedAt: Date) {
        self.init(
            id: dto.id, startedAt: dto.startedAt, endedAt: dto.endedAt, focusMinutes: dto.focusMinutes,
            summary: dto.summary, teacherNote: dto.teacherNote, parentPrompt: dto.parentPrompt, flags: dto.flags,
            problems: dto.problems.map {
                ProblemRecord(kind: $0.kind, summary: $0.summary, solvedBySelf: $0.solvedBySelf,
                              hintLevelReached: $0.hintLevelReached, createdAt: $0.createdAt ?? dto.startedAt)
            },
            syncedAt: syncedAt
        )
    }
}
