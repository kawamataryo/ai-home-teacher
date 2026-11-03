import Foundation

/// セッションの終わりに渡すもの。
struct SessionReflectionInput: Sendable {
    var sessionID: String = UUID().uuidString
    var startedAt: Date
    var endedAt: Date
    /// 集中した時間（タイマー #24 から）。
    var focusMinutes: Int
    /// 会話の履歴（TeacherBrain.history.messages）。ツールの呼び出しは読み飛ばす。
    var transcript: [ChatMessage]
    var problems: [ProblemRecord]
    /// TeacherBrain.sessionFlags。「要確認」はそのままセッションに残す。
    var flags: SessionFlags = SessionFlags()
}

/// ふり返りの結果。
struct SessionReflection: Equatable, Sendable {
    /// 親向けの要約。
    var summary: String
    /// 先生からのひとこと（親のダッシュボードに出す）。
    var teacherNote: String
    /// 子どもに読み上げるふり返り。
    var spokenClosing: String
    var memoryUpdates: MemoryUpdates
}

/// 終わったセッションを保存したあとの結果。
struct FinishedSession: Equatable, Sendable {
    var session: StudySessionRecord
    /// 先生が読み上げる、その日のふり返り。
    var spokenClosing: String
    /// Claude のふり返りを使えたか（false なら決まり文句で代わりにした）。
    var usedClaude: Bool
    /// 決まり文句にした理由（Claude の失敗の内容）。ログ用。
    var reflectionError: String? = nil
}

enum SessionReflectorError: Error, Equatable {
    /// record_reflection が返ってこなかった（max_tokens で切れたなど）。
    case noReflection(stopReason: String?)
    /// 中身が足りない（要約か、読み上げるふり返りが空）。
    case emptyReflection
}

/// セッションの終わりのふり返り（spec §3④）。
/// Worker 経由で Claude に会話と問題を渡し、strict tool use（record_reflection）で
/// 親向けの要約・先生のひとこと・子どもに話すふり返り・記憶の更新を返させる。
///
/// モデルは Sonnet。1セッションに1回だけなので費用は小さく、
/// 「何を覚えておくか / 何を忘れるか」の判断を誤ると次回以降の会話にずっと響くため、Haiku より質を取る。
/// そのぶん数秒かかるので、呼ぶ側は待っている間に定型句（「今日もがんばったね、ちょっと思い出すね」など）を流す。
///
/// 使い方:
/// ```swift
/// let reflector = SessionReflector(client: client)
/// let finished = try await reflector.finish(input, store: store)
/// tts.speak(finished.spokenClosing)
/// ```
struct SessionReflector: Sendable {
    static let claudePath = "/v1/claude"
    static let toolName = "record_reflection"
    /// 会話が長いときは、後ろからこの文字数だけ渡す。
    static let maxTranscriptCharacters = 24_000

    let client: WorkerClient
    let library: PromptLibrary
    let model: ClaudeModel
    let maxTokens: Int
    let timeZone: TimeZone
    /// Claude を待つ上限（#66）。過ぎたら決まり文句でふり返る（セッションは保存する）。nil なら待ち続ける
    var reflectionTimeout: Duration?

    init(
        client: WorkerClient,
        library: PromptLibrary = PromptLibrary(),
        model: ClaudeModel = .sonnet,
        maxTokens: Int = 2000,
        timeZone: TimeZone = .current
    ) {
        self.client = client
        self.library = library
        self.model = model
        self.maxTokens = maxTokens
        self.timeZone = timeZone
    }

    // MARK: - 終わりの流れ

    /// ふり返りを作り、セッションと記憶を保存する。
    /// Claude が失敗しても（通信・形の崩れ）セッションと「要確認」は必ず保存し、決まり文句でふり返る。
    func finish(_ input: SessionReflectionInput, store: some MemoryStore, now: Date = Date()) async throws -> FinishedSession {
        let memories = (try? await store.memories()) ?? []
        let reflection: SessionReflection
        var reflectionError: String?
        do {
            if let reflectionTimeout {
                let reflector = self
                reflection = try await DecisionClient.withTimeout(reflectionTimeout) {
                    try await reflector.reflect(input, memories: memories)
                }
            } else {
                reflection = try await reflect(input, memories: memories)
            }
        } catch {
            reflection = Self.fallback(for: input)
            reflectionError = String(describing: error)
        }

        let session = StudySessionRecord(
            id: input.sessionID,
            startedAt: input.startedAt,
            endedAt: input.endedAt,
            focusMinutes: input.focusMinutes,
            summary: reflection.summary,
            teacherNote: reflection.teacherNote,
            flags: input.flags.needsReview.map(\.reason),
            problems: input.problems
        ).clampedToServerLimits()
        try await store.saveSession(session)
        if !reflection.memoryUpdates.isEmpty {
            try await store.applyMemoryUpdates(reflection.memoryUpdates, now: now)
        }
        return FinishedSession(
            session: session, spokenClosing: reflection.spokenClosing,
            usedClaude: reflectionError == nil, reflectionError: reflectionError
        )
    }

    /// Claude にふり返りを作ってもらう。
    func reflect(_ input: SessionReflectionInput, memories: [MemoryRecord]) async throws -> SessionReflection {
        let body = try makeRequest(input, memories: memories)
        // tool_choice は auto なので、record_reflection を呼ばないことがある。そのときは1回だけやり直す
        for attempt in 1...2 {
            let data = try await client.postJSON(path: Self.claudePath, body: body)
            do {
                return try Self.parseResponse(data)
            } catch SessionReflectorError.noReflection(let reason) where attempt == 1 && reason != "max_tokens" {
                continue
            }
        }
        throw SessionReflectorError.noReflection(stopReason: nil)
    }

    // MARK: - リクエスト

    /// `POST /v1/claude` の本文。tool_choice は `auto`（いまのモデルはツールの強制を受け付けない）。
    /// record_reflection を必ず呼ぶよう、ユーザーメッセージの最後で指示する。
    struct Request: Encodable, Sendable {
        let model: ClaudeModel
        let maxTokens: Int
        let system: String
        let messages: [ChatMessage]
        let tools: [JSONValue]
        let toolChoice: JSONValue
        let stream: Bool

        private enum CodingKeys: String, CodingKey {
            case model, system, messages, tools, stream
            case maxTokens = "max_tokens"
            case toolChoice = "tool_choice"
        }
    }

    func makeRequest(_ input: SessionReflectionInput, memories: [MemoryRecord]) throws -> Request {
        Request(
            model: model,
            maxTokens: maxTokens,
            system: try systemPrompt(),
            messages: [ChatMessage(role: .user, content: [.text(userMessage(input, memories: memories))])],
            tools: [Self.tool],
            toolChoice: .object(["type": .string("auto")]),
            stream: false
        )
    }

    /// 先生のキャラクター（読み上げるふり返りの口調）＋ふり返りの指示。
    func systemPrompt() throws -> String {
        [try library.load(.teacher), try library.load(.reflection)].joined(separator: PromptLibrary.separator)
    }

    /// Claude に渡す今日の記録。問題の数はこちらで数えて渡す（数をまちがえて褒めないように）。
    func userMessage(_ input: SessionReflectionInput, memories: [MemoryRecord]) -> String {
        var lines: [String] = ["# 今日のセッション", ""]
        lines.append("- 日時：\(Self.dateText(input.startedAt, timeZone: timeZone))〜\(Self.timeText(input.endedAt, timeZone: timeZone))")
        lines.append("- 集中した時間：\(input.focusMinutes)分")

        let solved = input.problems.filter(\.solvedBySelf).count
        lines += ["", "# 取り組んだ問題（\(input.problems.count)問・自力で解けたのは\(solved)問）", ""]
        if input.problems.isEmpty {
            lines.append("（なし）")
        } else {
            for (i, p) in input.problems.enumerated() {
                lines.append("\(i + 1). [\(p.kind.rawValue)] \(p.summary)：\(Self.resultText(p))")
            }
        }

        lines += ["", "# いま覚えていること", ""]
        if memories.isEmpty {
            lines.append("（まだない）")
        } else {
            for category in MemoryCategory.allCases {
                let items = memories.filter { $0.category == category }.map(\.content)
                guard !items.isEmpty else { continue }
                lines.append("- \(category.label)（\(category.rawValue)）：\(items.joined(separator: " / "))")
            }
        }

        lines += ["", "# 会話", "", Self.transcriptText(input.transcript, limit: Self.maxTranscriptCharacters)]
        lines += ["", "必ず \(Self.toolName) ツールを呼んで、ふり返りを記録してください（文章だけで答えないこと）。"]
        return lines.joined(separator: "\n")
    }

    static func resultText(_ p: ProblemRecord) -> String {
        let hint = p.hintLevelReached == 0 ? "ヒントなし" : "ヒント\(p.hintLevelReached)段階目まで"
        return p.solvedBySelf ? "自力で解けた（\(hint)）" : "まだ解けていない・一緒に解いた（\(hint)）"
    }

    /// 会話を「子ども：」「先生：」の行にする。ツールの呼び出しと結果は入れない。長ければ後ろを残す。
    static func transcriptText(_ messages: [ChatMessage], limit: Int) -> String {
        let lines = messages.compactMap { message -> String? in
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return "\(message.role == .user ? "子ども" : "先生")：\(text)"
        }
        guard !lines.isEmpty else { return "（会話なし）" }
        let text = lines.joined(separator: "\n")
        guard text.count > limit else { return text }
        return "（前半は省略）\n" + String(text.suffix(limit))
    }

    static func dateText(_ date: Date, timeZone: TimeZone) -> String {
        format(date, "M月d日（E）H:mm", timeZone: timeZone)
    }

    static func timeText(_ date: Date, timeZone: TimeZone) -> String {
        format(date, "H:mm", timeZone: timeZone)
    }

    private static func format(_ date: Date, _ pattern: String, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        f.dateFormat = pattern
        return f.string(from: date)
    }

    // MARK: - ツール

    static let toolDescription = """
        学習セッションの終わりに、ふり返りを記録する。親向けの要約・先生のひとこと・子どもに読み上げるふり返り・記憶の更新を必ずまとめて渡す。
        """

    /// record_reflection のツール定義（strict）。
    static var tool: JSONValue {
        .object([
            "name": .string(toolName),
            "description": .string(toolDescription),
            "strict": .bool(true),
            "input_schema": inputSchema,
        ])
    }

    static var inputSchema: JSONValue {
        Schema.object([
            ("summary", Schema.string("親向けの要約。何に取り組み、どこでつまずき、どこを自力で解けたかを2〜4文で。正答の数字や言葉は書かない")),
            ("teacher_note", Schema.string("先生からのひとこと（親のダッシュボードに出す）。自力で解けたところやよかった点を、具体的に1〜2文でほめる")),
            ("spoken_closing", Schema.string("子どもに読み上げるふり返り。取り組んだ問題の数、自力で解けたところ、よかった点を、話し言葉で3〜5文。最後は次回が楽しみになるひと言")),
            ("memory", Schema.object(
                MemoryCategory.allCases.map { ($0.rawValue, changeSchema(for: $0)) },
                description: "次回の会話に使う記憶の更新。今日の会話でわかったことだけ。なければ空の配列"
            )),
        ])
    }

    private static func changeSchema(for category: MemoryCategory) -> JSONValue {
        Schema.object([
            ("add", Schema.array(Schema.string("短い言葉（例：サッカー、割合の文章題）"), description: "\(category.label)として新しく覚えること")),
            ("remove", Schema.array(Schema.string("「いま覚えていること」にある文をそのまま"), description: "\(category.label)から忘れること（もう当てはまらないもの）")),
        ])
    }

    // MARK: - レスポンス

    /// record_reflection の入力。
    struct ToolInput: Decodable, Equatable, Sendable {
        struct Change: Decodable, Equatable, Sendable {
            var add: [String]
            var remove: [String]
        }

        struct Memory: Decodable, Equatable, Sendable {
            var likes: Change?
            var events: Change?
            var weakPoints: Change?
        }

        var summary: String
        var teacherNote: String
        var spokenClosing: String
        var memory: Memory?
    }

    /// Messages API のレスポンス（stream: false）から record_reflection を読む。
    static func parseResponse(_ data: Data) throws -> SessionReflection {
        let response = try JSONDecoder().decode(JSONValue.self, from: data)
        let stopReason = response["stop_reason"]?.stringValue
        guard case .array(let blocks)? = response["content"],
              let input = blocks.first(where: {
                  $0["type"]?.stringValue == "tool_use" && $0["name"]?.stringValue == toolName
              })?["input"],
              stopReason != "max_tokens"
        else { throw SessionReflectorError.noReflection(stopReason: stopReason) }
        return try reflection(from: input)
    }

    static func reflection(from input: JSONValue) throws -> SessionReflection {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decoded = try decoder.decode(ToolInput.self, from: input.jsonData())
        let summary = decoded.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let closing = decoded.spokenClosing.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty, !closing.isEmpty else { throw SessionReflectorError.emptyReflection }

        var updates = MemoryUpdates()
        let changes: [(MemoryCategory, ToolInput.Change?)] = [
            (.likes, decoded.memory?.likes), (.events, decoded.memory?.events), (.weakPoints, decoded.memory?.weakPoints),
        ]
        for (category, change) in changes {
            guard let change else { continue }
            updates[category] = MemoryUpdates.Change(add: change.add, remove: change.remove)
        }
        return SessionReflection(
            summary: summary,
            teacherNote: decoded.teacherNote.trimmingCharacters(in: .whitespacesAndNewlines),
            spokenClosing: closing,
            memoryUpdates: updates
        )
    }

    // MARK: - 代わり

    /// Claude が使えないときのふり返り。数えられることだけを言う。記憶は更新しない。
    static func fallback(for input: SessionReflectionInput) -> SessionReflection {
        let total = input.problems.count
        let solved = input.problems.filter(\.solvedBySelf)
        let closing: String
        let summary: String
        if total == 0 {
            closing = "今日もおつかれさま！一緒に勉強できて楽しかったよ。またね！"
            summary = "\(input.focusMinutes)分勉強した（ふり返りは作れなかった）"
        } else {
            let solvedText = solved.isEmpty ? "最後まであきらめずに考えたね。" : "そのうち\(solved.count)問は自分の力で解けたね！"
            closing = "今日は\(total)問やったね。\(solvedText)おつかれさま、また一緒にやろうね！"
            let list = input.problems.map { "\($0.summary)（\($0.solvedBySelf ? "自力で解けた" : "一緒に解いた")）" }
            summary = "\(input.focusMinutes)分で\(total)問に取り組んだ（自力 \(solved.count)問）：" + list.joined(separator: "、")
        }
        return SessionReflection(summary: summary, teacherNote: "", spokenClosing: closing, memoryUpdates: MemoryUpdates())
    }
}
