import Foundation
import SwiftData

/// セッションの記録と記憶の保存先。#28 の同期もこの口を使う。
protocol MemoryStore: Sendable {
    /// セッションを保存する。同じ id があれば上書き。保存時に同期 API の上限に収める。
    func saveSession(_ session: StudySessionRecord) async throws
    /// 始まった時刻の新しい順。
    func recentSessions(limit: Int) async throws -> [StudySessionRecord]
    /// まだサーバーに送っていないセッション（古い順）。
    func unsyncedSessions() async throws -> [StudySessionRecord]
    /// サーバーに送れたら呼ぶ。
    func markSynced(sessionID: String, at date: Date) async throws

    /// 記憶。カテゴリ順、各カテゴリは新しい順。`category` を渡すとそのカテゴリだけ。
    func memories(category: MemoryCategory?) async throws -> [MemoryRecord]
    /// そのカテゴリの記憶を丸ごと入れ替える（サーバーから取ってきたものを入れるときなど）。
    func replaceMemories(category: MemoryCategory, with items: [MemoryRecord]) async throws
    /// ふり返りの記憶の更新を足し込む（MemoryMerger のルール）。
    func applyMemoryUpdates(_ updates: MemoryUpdates, now: Date) async throws
}

extension MemoryStore {
    /// 直前のセッション。
    func latestSession() async throws -> StudySessionRecord? {
        try await recentSessions(limit: 1).first
    }

    func memories() async throws -> [MemoryRecord] {
        try await memories(category: nil)
    }
}

/// ふり返りで出た記憶の更新。カテゴリごとに足すものと消すもの。
struct MemoryUpdates: Equatable, Sendable {
    struct Change: Equatable, Sendable {
        var add: [String] = []
        var remove: [String] = []
    }

    var changes: [MemoryCategory: Change] = [:]

    subscript(category: MemoryCategory) -> Change {
        get { changes[category] ?? Change() }
        set { changes[category] = newValue }
    }

    var isEmpty: Bool {
        changes.values.allSatisfy { $0.add.isEmpty && $0.remove.isEmpty }
    }
}

/// 記憶の足し込みのルール。
/// - 消すものを先に消し、そのあと足す
/// - 同じ内容かは、前後の空白・連続する空白・大文字小文字・全角半角の違いを無視して比べる（足すときも消すときも）
/// - すでにある内容を足したら、更新日時だけ新しくする（重ねて入れない）
/// - 空の内容は無視し、長すぎる内容は同期 API の上限（500 文字）で切る
/// - 1カテゴリ `capPerCategory` 件まで。あふれたら古いものから捨てる
enum MemoryMerger {
    static let capPerCategory = 20

    static func merge(
        existing: [MemoryRecord],
        change: MemoryUpdates.Change,
        category: MemoryCategory,
        now: Date,
        cap: Int = capPerCategory
    ) -> [MemoryRecord] {
        let removeKeys = Set(change.remove.map(normalizedKey).filter { !$0.isEmpty })
        var items = existing
            .filter { $0.category == category }
            .filter { !removeKeys.contains(normalizedKey($0.content)) }

        for raw in change.add {
            let content = String(clean(raw).prefix(ServerLimits.memoryContent))
            let key = normalizedKey(content)
            guard !key.isEmpty else { continue }
            if let index = items.firstIndex(where: { normalizedKey($0.content) == key }) {
                items[index].updatedAt = now
            } else {
                items.append(MemoryRecord(category: category, content: content, updatedAt: now))
            }
        }

        // 新しい順に並べて、上限より古いものを捨てる（同じ時刻なら後から足したほうを新しいとみなす）
        let sorted = items.enumerated()
            .sorted { a, b in
                a.element.updatedAt != b.element.updatedAt ? a.element.updatedAt > b.element.updatedAt : a.offset > b.offset
            }
            .map(\.element)
        return Array(sorted.prefix(max(cap, 0)))
    }

    /// 前後の空白を取り、連続する空白を1つにする。
    static func clean(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// 同じ内容かを比べるためのキー。
    static func normalizedKey(_ text: String) -> String {
        clean(text).folding(options: [.caseInsensitive, .widthInsensitive], locale: Locale(identifier: "ja_JP"))
    }
}

/// SwiftData に保存する実装。@Model はこの actor の中だけで触る。
@ModelActor
actor SwiftDataMemoryStore: MemoryStore {
    // アプリには JSON Schema の DSL（Schema）もあるので、SwiftData のほうは名前空間を付ける
    static var schema: SwiftData.Schema { SwiftData.Schema([StudySession.self, MemoryItem.self]) }

    /// アプリ用（端末に保存）。テストでは `inMemory: true`。
    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: inMemory)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /// テスト用：メモリ上だけのストア。
    static func inMemory() throws -> SwiftDataMemoryStore {
        SwiftDataMemoryStore(modelContainer: try makeContainer(inMemory: true))
    }

    func saveSession(_ session: StudySessionRecord) throws {
        let record = session.clampedToServerLimits()
        if let existing = try fetchSession(id: record.id) {
            existing.update(from: record)
        } else {
            modelContext.insert(StudySession(record))
        }
        try modelContext.save()
    }

    func recentSessions(limit: Int) throws -> [StudySessionRecord] {
        var descriptor = FetchDescriptor<StudySession>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        descriptor.fetchLimit = max(limit, 0)
        return try modelContext.fetch(descriptor).map(\.record)
    }

    func unsyncedSessions() throws -> [StudySessionRecord] {
        let descriptor = FetchDescriptor<StudySession>(
            predicate: #Predicate { $0.syncedAt == nil },
            sortBy: [SortDescriptor(\.startedAt)]
        )
        return try modelContext.fetch(descriptor).map(\.record)
    }

    func markSynced(sessionID: String, at date: Date) throws {
        guard let session = try fetchSession(id: sessionID) else { return }
        session.syncedAt = date
        try modelContext.save()
    }

    func memories(category: MemoryCategory?) throws -> [MemoryRecord] {
        let categories = category.map { [$0] } ?? MemoryCategory.allCases
        return try categories.flatMap { try fetchMemories($0).compactMap(\.record) }
    }

    func replaceMemories(category: MemoryCategory, with items: [MemoryRecord]) throws {
        try writeMemories(category: category, items: items.filter { $0.category == category })
        try modelContext.save()
    }

    func applyMemoryUpdates(_ updates: MemoryUpdates, now: Date) throws {
        for category in MemoryCategory.allCases {
            let change = updates[category]
            guard !change.add.isEmpty || !change.remove.isEmpty else { continue }
            let existing = try fetchMemories(category).compactMap(\.record)
            let merged = MemoryMerger.merge(existing: existing, change: change, category: category, now: now)
            try writeMemories(category: category, items: merged)
        }
        try modelContext.save()
    }

    // MARK: - 内部

    private func fetchSession(id: String) throws -> StudySession? {
        var descriptor = FetchDescriptor<StudySession>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    /// 新しい順。
    private func fetchMemories(_ category: MemoryCategory) throws -> [MemoryItem] {
        let raw = category.rawValue
        let descriptor = FetchDescriptor<MemoryItem>(
            predicate: #Predicate { $0.category == raw },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor)
    }

    private func writeMemories(category: MemoryCategory, items: [MemoryRecord]) throws {
        for item in try fetchMemories(category) {
            modelContext.delete(item)
        }
        for item in items {
            modelContext.insert(MemoryItem(item))
        }
    }
}
