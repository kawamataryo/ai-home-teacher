import Foundation
import SwiftData

// セッションの記録と記憶（spec §3④・§5）。保存するのは文字の情報だけ。
// 形は Worker の同期 API（worker/README.md の POST /v1/sessions・PUT /v1/memory）に揃える。
// SwiftData の @Model は Sendable ではないので、ストアの外とは下の値型（〜Record）でやりとりする。

/// セッションで取り組んだ1問。
struct ProblemRecord: Codable, Equatable, Sendable {
    var kind: ProblemKind
    /// 問題の要約（例：割合：もとにする量を求める）。正答は入れない。
    var summary: String
    var solvedBySelf: Bool
    /// 到達したヒントの段階 0〜4（0 = ヒントなし）。
    var hintLevelReached: Int
    var createdAt: Date

    init(kind: ProblemKind, summary: String, solvedBySelf: Bool, hintLevelReached: Int = 0, createdAt: Date) {
        self.kind = kind
        self.summary = summary
        self.solvedBySelf = solvedBySelf
        self.hintLevelReached = hintLevelReached
        self.createdAt = createdAt
    }
}

/// 記憶のカテゴリ。同期 API の `category` と揃える。
enum MemoryCategory: String, Codable, Sendable, CaseIterable {
    /// 好きなこと
    case likes
    /// 最近の出来事
    case events
    /// 苦手な単元
    case weakPoints = "weak_points"

    var label: String {
        switch self {
        case .likes: "好きなこと"
        case .events: "最近の出来事"
        case .weakPoints: "苦手な単元"
        }
    }
}

/// 終わったセッション1回分（値型）。#28 の同期はこれを POST /v1/sessions に変換して送る。
struct StudySessionRecord: Equatable, Sendable {
    /// アプリが作る UUID の文字列。同じ id で保存し直すと上書き。
    var id: String
    var startedAt: Date
    var endedAt: Date
    var focusMinutes: Int
    /// 親向けの要約。
    var summary: String
    /// 先生からのひとこと（親のダッシュボードに出す）。
    var teacherNote: String
    /// 「要確認」メモ（SessionFlags の reason）。
    var flags: [String]
    var problems: [ProblemRecord]
    /// サーバーに送った時刻。#28 が送るまでは nil。
    var syncedAt: Date?

    init(
        id: String = UUID().uuidString,
        startedAt: Date,
        endedAt: Date,
        focusMinutes: Int,
        summary: String = "",
        teacherNote: String = "",
        flags: [String] = [],
        problems: [ProblemRecord] = [],
        syncedAt: Date? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.focusMinutes = focusMinutes
        self.summary = summary
        self.teacherNote = teacherNote
        self.flags = flags
        self.problems = problems
        self.syncedAt = syncedAt
    }

    /// 同期 API の制限に収める（送ったときに 400 にならないように、保存の時点でそろえる）。
    func clampedToServerLimits() -> StudySessionRecord {
        var s = self
        if s.endedAt < s.startedAt { s.endedAt = s.startedAt }
        s.focusMinutes = min(max(s.focusMinutes, 0), ServerLimits.focusMinutesMax)
        s.summary = String(s.summary.prefix(ServerLimits.summary))
        s.teacherNote = String(s.teacherNote.prefix(ServerLimits.teacherNote))
        s.flags = s.flags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(ServerLimits.flagsCount)
            .map { String($0.prefix(ServerLimits.flag)) }
        s.problems = s.problems.compactMap { p in
            let summary = p.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !summary.isEmpty else { return nil }
            var p = p
            p.summary = String(summary.prefix(ServerLimits.problemSummary))
            p.hintLevelReached = min(max(p.hintLevelReached, 0), ServerLimits.hintLevelMax)
            return p
        }
        s.problems = Array(s.problems.prefix(ServerLimits.problemsCount))
        return s
    }
}

/// 記憶1件（値型）。#28 の同期はカテゴリごとに PUT /v1/memory で送る。
struct MemoryRecord: Equatable, Sendable {
    var category: MemoryCategory
    var content: String
    var updatedAt: Date
}

/// 同期 API（worker/src/sync.ts）の上限。
enum ServerLimits {
    static let summary = 4000
    static let teacherNote = 1000
    static let flagsCount = 20
    static let flag = 500
    static let problemsCount = 100
    static let problemSummary = 1000
    static let hintLevelMax = 4
    static let focusMinutesMax = 1440
    static let memoryContent = 500
}

// MARK: - SwiftData

/// SwiftData に保存するセッション。外からは StudySessionRecord で扱う。
@Model
final class StudySession {
    @Attribute(.unique) var id: String
    var startedAt: Date
    var endedAt: Date
    var focusMinutes: Int
    var summary: String
    var teacherNote: String
    var flags: [String]
    /// 問題は JSON にして持つ（Codable の配列をそのまま持つより、スキーマが変わっても壊れにくい）。
    var problemsJSON: Data
    var syncedAt: Date?

    init(_ record: StudySessionRecord) {
        id = record.id
        startedAt = record.startedAt
        endedAt = record.endedAt
        focusMinutes = record.focusMinutes
        summary = record.summary
        teacherNote = record.teacherNote
        flags = record.flags
        problemsJSON = Self.encode(record.problems)
        syncedAt = record.syncedAt
    }

    func update(from record: StudySessionRecord) {
        startedAt = record.startedAt
        endedAt = record.endedAt
        focusMinutes = record.focusMinutes
        summary = record.summary
        teacherNote = record.teacherNote
        flags = record.flags
        problemsJSON = Self.encode(record.problems)
        syncedAt = record.syncedAt
    }

    var record: StudySessionRecord {
        StudySessionRecord(
            id: id, startedAt: startedAt, endedAt: endedAt, focusMinutes: focusMinutes,
            summary: summary, teacherNote: teacherNote, flags: flags,
            problems: (try? Self.decoder.decode([ProblemRecord].self, from: problemsJSON)) ?? [],
            syncedAt: syncedAt
        )
    }

    private static func encode(_ problems: [ProblemRecord]) -> Data {
        (try? encoder.encode(problems)) ?? Data("[]".utf8)
    }

    // 日時は既定（基準日からの秒数）のまま。ISO 8601 だと秒未満が落ちて、読み戻した値が変わる。
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    private static let decoder = JSONDecoder()
}

/// SwiftData に保存する記憶。カテゴリは述語で絞りやすいように文字列で持つ。
@Model
final class MemoryItem {
    var category: String
    var content: String
    var updatedAt: Date

    init(_ record: MemoryRecord) {
        category = record.category.rawValue
        content = record.content
        updatedAt = record.updatedAt
    }

    var record: MemoryRecord? {
        MemoryCategory(rawValue: category).map { MemoryRecord(category: $0, content: content, updatedAt: updatedAt) }
    }
}
