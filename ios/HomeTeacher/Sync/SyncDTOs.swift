import Foundation

// Worker の同期 API（worker/README.md「同期 API」）とやりとりする形。
// サーバーの入力は .strict() なので、サーバーが付けるフィールド（updated_at、problems[].id）は送らない。

// ProblemKind は Shared/ProblemKind.swift、MemoryCategory は Memory/MemoryModels.swift のものを使う（rawValue は同期 API と同じ）。

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
    /// 今夜の声かけ（#158）。
    var parentPrompt: String
    /// 「要確認」メモ。
    var flags: [String]
    var problems: [ProblemDTO]
    /// サーバーが保存した時刻。送るときは使わない。
    var updatedAt: Date?

    init(
        id: String, childID: String? = nil, startedAt: Date, endedAt: Date, focusMinutes: Int,
        summary: String = "", teacherNote: String = "", parentPrompt: String = "", flags: [String] = [], problems: [ProblemDTO] = [],
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.childID = childID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.focusMinutes = focusMinutes
        self.summary = summary
        self.teacherNote = teacherNote
        self.parentPrompt = parentPrompt
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
        case parentPrompt = "parent_prompt"
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
        parentPrompt = try c.decodeIfPresent(String.self, forKey: .parentPrompt) ?? ""
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
        try c.encode(parentPrompt, forKey: .parentPrompt)
        try c.encode(flags, forKey: .flags)
        try c.encode(problems, forKey: .problems)
    }
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
    /// このカテゴリをサーバーの内容で揃えたときのサーバー時刻（#160）。これより後に親が消した記憶は、サーバーが取り除く。
    var basedOn: Date?

    private enum CodingKeys: String, CodingKey {
        case category, items
        case childID = "child_id"
        case basedOn = "based_on"
    }
}

/// 親の伝言（#159）。GET /v1/messages の1件。端末では SyncState に置いて、先生が話し終えるまで持っておく。
struct ParentMessage: Codable, Equatable, Sendable {
    var id: String
    /// 先生が言う送り主の呼び方。親が決める（先生に推測させない）。
    var senderLabel: String
    var body: String
    var createdAt: Date

    private enum CodingKeys: String, CodingKey {
        case id, body
        case senderLabel = "sender_label"
        case createdAt = "created_at"
    }
}

/// GET /v1/messages のレスポンス。
struct ParentMessageListResponse: Codable, Equatable, Sendable {
    var messages: [ParentMessage]
}

/// POST /v1/messages/:id/delivered の本文。話し終えた時刻を送る（オフラインであとから送っても、時刻がずれない）。
struct ParentMessageDeliveredRequest: Codable, Equatable, Sendable {
    var deliveredAt: Date

    private enum CodingKeys: String, CodingKey {
        case deliveredAt = "delivered_at"
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
    /// サーバーが読んだときの時刻（次の PUT の based_on）。
    var serverTime: Date?

    private enum CodingKeys: String, CodingKey {
        case memories
        case serverTime = "server_time"
    }
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
