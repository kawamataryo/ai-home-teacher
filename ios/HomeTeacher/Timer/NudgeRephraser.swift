import Foundation

/// 時間での声かけの言い回しを Haiku に変えてもらう（spec §3④。設定でオンにしたときだけ）。
///
/// 待ち時間を増やさないよう `timeout` で諦め、使えない答え（長い・空・意味が変わった）なら nil を返す。
/// nil なら定型句をそのまま（同梱の音声で）話す。変えた言い回しは音声がないので、その場で合成する。
struct NudgeRephraser: Sendable {
    static let claudePath = "/v1/claude"
    /// 言い換えの長さの上限（1 文で短く）
    static let maxCharacters = 40

    let client: WorkerClient
    let library: PromptLibrary
    var timeout: Duration = .seconds(2)

    init(client: WorkerClient, library: PromptLibrary = PromptLibrary(), timeout: Duration = .seconds(2)) {
        self.client = client
        self.library = library
        self.timeout = timeout
    }

    /// どんな場面の声かけか（Haiku に渡す）
    static func situation(of phrase: FixedPhrase) -> String {
        switch phrase {
        case .breakTime: "集中の時間が終わったので、休憩に誘う"
        case .breakOver: "休憩が終わったので、勉強の続きに戻ろうと声をかける"
        case .fiveMinutesLeft: "集中の時間の残りが5分なので、あと少しがんばろうと励ます"
        }
    }

    func makeRequest(_ nudge: TeacherNudge) throws -> MessagesRequest {
        let user = "場面：\(Self.situation(of: nudge.phrase))\nいつもの言い方：\(nudge.text)"
        return MessagesRequest(
            model: .haiku, maxTokens: 100, system: try library.load(.nudgeVariation),
            messages: [ChatMessage(role: .user, content: [.text(user)])], stream: false,
            thinking: MessagesRequest.thinkingDisabled
        )
    }

    /// 言い換えた 1 文。失敗・時間切れ・使えない答えなら nil
    func rephrase(_ nudge: TeacherNudge) async -> String? {
        guard let request = try? makeRequest(nudge) else { return nil }
        let client = client
        guard let data = try? await DecisionClient.withTimeout(timeout, {
            try await client.postJSON(path: Self.claudePath, body: request)
        }) else { return nil }
        return Self.parse(data).flatMap { Self.validated($0, for: nudge) }
    }

    /// Messages API のレスポンス（stream: false）の文
    static func parse(_ data: Data) -> String? {
        guard let response = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .array(let blocks)? = response["content"]
        else { return nil }
        let text = blocks.compactMap { $0["type"]?.stringValue == "text" ? $0["text"]?.stringValue : nil }.joined()
        return text.isEmpty ? nil : text
    }

    /// 話してよい言い換えか。1 行・短い・意味が変わっていない（残り時間の数字が残っている）
    static func validated(_ raw: String, for nudge: TeacherNudge) -> String? {
        var text = EmotionTag.strip(raw).text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "「」\"'"))
        guard !text.isEmpty, text.count <= maxCharacters, !text.contains("\n"),
              !text.contains("["), !text.contains("［")
        else { return nil }
        if nudge.phrase == .fiveMinutesLeft, !["5", "５", "五"].contains(where: text.contains) { return nil }
        return text
    }
}
