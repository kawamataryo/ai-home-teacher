import Foundation

enum ProblemAnalyzerError: Error, Equatable {
    /// report_analysis が呼ばれなかった。
    case missingAnalysis
    /// max_tokens で切れて、ツールの入力が途中までしかない。
    case truncated
    /// report_analysis の入力が読めなかった。
    case invalidAnalysis(String)
}

/// 分析の結果。黒板の図は Sonnet が show_board / render_svg も呼んだときだけ入る。
struct AnalysisResult: Equatable, Sendable {
    var analysis: ProblemAnalysis
    var boards: [BoardContent]
}

/// 撮影した問題を Sonnet に渡し、report_analysis（strict tool use）で分析結果を受け取る（spec §3②・§4）。
///
/// 使い方:
/// ```swift
/// guard let jpeg = ImageResizer.jpegData(from: photo) else { return }
/// let analyzer = ProblemAnalyzer(client: client)
/// let result = try await analyzer.analyze(jpegData: jpeg, conversation: await brain.history.messages)
/// var ladder = HintLadder(analysis: result.analysis)
/// let note = TeacherNote.make(analysis: result.analysis, ladder: ladder)
/// ```
/// 画像は送ったあとに呼び出し側で破棄する。会話履歴（Haiku と共有）には画像を入れない。
struct ProblemAnalyzer: Sendable {
    static let claudePath = "/v1/claude"
    /// 会話のうち、分析に渡す直近の発言の数。
    static let defaultConversationLimit = 12

    private let client: WorkerClient
    private let library: PromptLibrary
    let model: ClaudeModel
    let maxTokens: Int
    /// 黒板のツール（show_board / render_svg）も渡すか。
    let includeBoardTools: Bool

    init(
        client: WorkerClient,
        library: PromptLibrary = PromptLibrary(),
        model: ClaudeModel = .sonnet,
        maxTokens: Int = 4096,
        includeBoardTools: Bool = true
    ) {
        self.client = client
        self.library = library
        self.model = model
        self.maxTokens = maxTokens
        self.includeBoardTools = includeBoardTools
    }

    static let instructions = """
        あなたは小学5年生の家庭教師の「頭脳」です。子どもが撮影した問題（またはノート・作文）の写真と、それまでの会話を読み、report_analysis ツールで分析結果を報告します。

        - kind：資料・グラフ・表の読み取りは reading、算数・理科的な思考は thinking、作文・記述は writing
        - answer：正答の短い形だけ（例：24cm²、イ、3/4）。answer_variants に同じ答えの別の書き方（小数・分数・漢数字・単位の言いかえなど）を入れる
        - hint_steps：下の「ヒントの出し方」の段階に合わせて、段階ごとの問いかけを順に書く。どの段階にも正答そのものは書かない。4段目は、答えの手前で「ということは？」と子どもに言わせる形で終える
        - 写真に問題が複数あるときは、会話から子どもが聞いている問題を選ぶ。わからなければ最初の問題
        - 写真が読めないときも report_analysis を呼び、problem_summary にそのことを書き、answer は空文字にする
        """

    /// Sonnet に渡すシステムプロンプト。分析の指示 → ヒントの出し方 →（黒板を使うなら）部品カタログ。
    func systemPrompt() throws -> String {
        var parts = [Self.instructions, try library.load(.hintLadder)]
        if includeBoardTools {
            parts.append(try library.boardCatalog())
        }
        return parts.joined(separator: PromptLibrary.separator)
    }

    /// 会話を「子ども：」「先生：」の文字だけにする。
    /// ツールの呼び出しを含む生の履歴をそのまま送ると、tool_use と tool_result の対が崩れて API が受け付けないことがある。
    static func transcript(of messages: [ChatMessage], limit: Int = defaultConversationLimit) -> String {
        messages
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .suffix(limit)
            .map { "\($0.role == .user ? "子ども" : "先生")：\($0.text)" }
            .joined(separator: "\n")
    }

    /// Worker に送る本文（Messages API）。
    func makeRequestBody(jpegData: Data, conversation: [ChatMessage], imageID: String) throws -> JSONValue {
        let talk = Self.transcript(of: conversation)
        let text = """
            写真の ID：\(imageID)
            これまでの会話：
            \(talk.isEmpty ? "（なし）" : talk)

            この写真の問題を分析して、report_analysis で報告してください。
            """
        var tools = [AnalysisTool.definition]
        if includeBoardTools { tools += BoardTools.all }
        return .object([
            "model": .string(model.rawValue),
            "max_tokens": .number(Double(maxTokens)),
            "stream": .bool(false),
            "system": .string(try systemPrompt()),
            "tools": .array(tools),
            "tool_choice": AnalysisTool.toolChoice,
            "messages": .array([
                .object([
                    "role": .string(ChatRole.user.rawValue),
                    "content": .array([
                        .object([
                            "type": .string("image"),
                            "source": .object([
                                "type": .string("base64"),
                                "media_type": .string("image/jpeg"),
                                "data": .string(jpegData.base64EncodedString()),
                            ]),
                        ]),
                        .object(["type": .string("text"), "text": .string(text)]),
                    ]),
                ]),
            ]),
        ])
    }

    /// 写真（長辺 2048px の JPEG）と会話から問題を分析する。
    func analyze(jpegData: Data, conversation: [ChatMessage] = [], imageID: String = "photo_1") async throws -> AnalysisResult {
        let body = try makeRequestBody(jpegData: jpegData, conversation: conversation, imageID: imageID)
        let data = try await client.postJSON(path: Self.claudePath, body: body.jsonData())
        return try Self.decodeResponse(data)
    }

    private struct Response: Decodable {
        var content: [JSONValue]
        var stopReason: String?

        private enum CodingKeys: String, CodingKey {
            case content
            case stopReason = "stop_reason"
        }
    }

    /// Messages API の応答（非ストリーミング）から分析結果と黒板の図を取り出す。
    /// 知らない種類の block（thinking など）は無視する。
    static func decodeResponse(_ data: Data) throws -> AnalysisResult {
        let response = try JSONDecoder().decode(Response.self, from: data)
        var analysis: ProblemAnalysis?
        var boards: [BoardContent] = []
        for block in response.content where block["type"]?.stringValue == "tool_use" {
            guard let name = block["name"]?.stringValue, let input = block["input"] else { continue }
            switch name {
            case AnalysisTool.name:
                do {
                    analysis = try AnalysisTool.decode(input)
                } catch {
                    if response.stopReason == "max_tokens" { throw ProblemAnalyzerError.truncated }
                    throw ProblemAnalyzerError.invalidAnalysis(String(describing: error))
                }
            case BoardTools.showBoardName, BoardTools.renderSVGName:
                boards.append(BoardTools.content(toolName: name, input: input))
            default:
                continue
            }
        }
        guard let analysis else {
            throw response.stopReason == "max_tokens" ? ProblemAnalyzerError.truncated : ProblemAnalyzerError.missingAnalysis
        }
        return AnalysisResult(analysis: analysis, boards: boards)
    }
}
