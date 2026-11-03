import Foundation

// Worker の同期 API（worker/README.md「同期 API」）とやりとりする形。
// サーバーの入力は .strict() なので、サーバーが付けるフィールド（updated_at、problems[].id）は送らない。

/// 問題の種類（spec §3②）。
enum ProblemKind: String, Codable, Sendable, CaseIterable {
    case reading
    case thinking
    case writing
}

/// セッションで取り組んだ1問。
struct ProblemDTO: Codable, Equatable, Sendable {
    /// サーバーが付ける id。送るときは使わない。
    var id: String?
    var kind: ProblemKind
    var summary: String
    var solvedBySelf: Bool
    /// 到達したヒントの段階 0〜4（0 = ヒントなし）。
    var hintLevelReached: Int
    /// 省略するとサーバーは started_at にする。
    var createdAt: Date?

    init(
        id: String? = nil, kind: ProblemKind, summary: String, solvedBySelf: Bool,
        hintLevelReached: Int = 0, createdAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.summary = summary
        self.solvedBySelf = solvedBySelf
        self.hintLevelReached = hintLevelReached
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, summary
        case solvedBySelf = "solved_by_self"
        case hintLevelReached = "hint_level_reached"
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        kind = try c.decode(ProblemKind.self, forKey: .kind)
        summary = try c.decode(String.self, forKey: .summary)
        solvedBySelf = try c.decode(Bool.self, forKey: .solvedBySelf)
        hintLevelReached = try c.decodeIfPresent(Int.self, forKey: .hintLevelReached) ?? 0
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(summary, forKey: .summary)
        try c.encode(solvedBySelf, forKey: .solvedBySelf)
        try c.encode(hintLevelReached, forKey: .hintLevelReached)
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
    }
}

/// 1回の学習セッション。POST /v1/sessions の本文であり、GET /v1/sessions の1件でもある。
struct SessionDTO: Codable, Equatable, Sendable {
    /// アプリが作る UUID。同じ id で送り直すとサーバーで上書きされる。
    var id: String
    /// 省略すると家族の最初の子ども。
    var childID: String?
    var startedAt: Date
    var endedAt: Date
    var focusMinutes: Int
    var summary: String
    /// 先生のひとこと。
    var teacherNote: String
    /// 「要確認」メモ。
    var flags: [String]
    var problems: [ProblemDTO]
    /// サーバーが保存した時刻。送るときは使わない。
    var updatedAt: Date?

    init(
        id: String, childID: String? = nil, startedAt: Date, endedAt: Date, focusMinutes: Int,
        summary: String = "", teacherNote: String = "", flags: [String] = [], problems: [ProblemDTO] = [],
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.childID = childID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.focusMinutes = focusMinutes
        self.summary = summary
        self.teacherNote = teacherNote
        self.flags = flags
        self.problems = problems
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, summary, flags, problems
        case childID = "child_id"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case focusMinutes = "focus_minutes"
        case teacherNote = "teacher_note"
        case updatedAt = "updated_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        childID = try c.decodeIfPresent(String.self, forKey: .childID)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endedAt = try c.decode(Date.self, forKey: .endedAt)
        focusMinutes = try c.decode(Int.self, forKey: .focusMinutes)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        teacherNote = try c.decodeIfPresent(String.self, forKey: .teacherNote) ?? ""
        flags = try c.decodeIfPresent([String].self, forKey: .flags) ?? []
        problems = try c.decodeIfPresent([ProblemDTO].self, forKey: .problems) ?? []
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(childID, forKey: .childID)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encode(endedAt, forKey: .endedAt)
        try c.encode(focusMinutes, forKey: .focusMinutes)
        try c.encode(summary, forKey: .summary)
        try c.encode(teacherNote, forKey: .teacherNote)
        try c.encode(flags, forKey: .flags)
        try c.encode(problems, forKey: .problems)
    }
}

/// 記憶のカテゴリ（spec §5 の memories.category）。
enum MemoryCategory: String, Codable, Sendable, CaseIterable {
    /// 好きなこと
    case likes
    /// 最近の出来事
    case events
    /// 苦手な単元
    case weakPoints = "weak_points"
}

/// サーバーに保存された記憶の1件。
struct MemoryDTO: Codable, Equatable, Sendable {
    var id: String
    var childID: String
    var category: MemoryCategory
    var content: String
    var updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id, category, content
        case childID = "child_id"
        case updatedAt = "updated_at"
    }
}

/// PUT /v1/memory の items の1件。
struct MemoryItemDTO: Codable, Equatable, Sendable {
    var content: String
}

/// PUT /v1/memory の本文。そのカテゴリの記憶を items でまるごと入れ替える。
struct MemoryPutRequest: Codable, Equatable, Sendable {
    var category: MemoryCategory
    var items: [MemoryItemDTO]
    var childID: String?

    private enum CodingKeys: String, CodingKey {
        case category, items
        case childID = "child_id"
    }
}

/// POST /v1/sessions のレスポンス。
struct SessionResponse: Codable, Equatable, Sendable {
    var session: SessionDTO
}

/// GET /v1/sessions のレスポンス。
struct SessionListResponse: Codable, Equatable, Sendable {
    var sessions: [SessionDTO]
    /// 次の同期で since に渡す時刻。
    var serverTime: Date

    private enum CodingKeys: String, CodingKey {
        case sessions
        case serverTime = "server_time"
    }
}

/// GET /v1/memory と PUT /v1/memory のレスポンス。
struct MemoryListResponse: Codable, Equatable, Sendable {
    var memories: [MemoryDTO]
}

/// 同期 API 用の JSON の読み書き。時刻はタイムゾーン付きの ISO 8601。
enum SyncCoding {
    /// 送るときは UTC のミリ秒付き（サーバーが返す形と同じ "2026-11-03T07:00:00.000Z"）。
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(formatDate(date))
        }
        return encoder
    }()

    /// 小数秒のあり・なし、Z・+09:00 のどれでも読む。
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let text = try c.decode(String.self)
            guard let date = parseDate(text) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "ISO 8601 の時刻ではない: \(text)")
            }
            return date
        }
        return decoder
    }()

    static func formatDate(_ date: Date) -> String {
        date.formatted(withFraction)
    }

    static func parseDate(_ text: String) -> Date? {
        (try? withFraction.parse(text)) ?? (try? withoutFraction.parse(text))
    }

    private static let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let withoutFraction = Date.ISO8601FormatStyle()
}
