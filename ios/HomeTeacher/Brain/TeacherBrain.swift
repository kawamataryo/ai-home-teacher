import Foundation

/// 先生の返事の中身。文と、黒板の図（show_board）が届いた順に流れる。
enum TeacherOutput: Equatable, Sendable {
    case sentence(String)
    case board(BoardContent)
    /// インターネットで調べている様子（#114）
    case research(ResearchUpdate)
}

enum TeacherBrainError: Error, Equatable {
    /// ストリームの途中で API がエラーを返した。
    case api(type: String, message: String)
}

/// 先生の頭脳。Worker 経由で Claude をストリーミングで呼び、文ごとに返す（spec §3①）。
///
/// 使い方:
/// ```swift
/// let library = PromptLibrary()
/// let brain = TeacherBrain(
///     client: client,
///     systemPrompt: try library.conversationSystemPrompt(mode: .study),
///     tools: try library.conversationTools()
/// )
/// for try await sentence in await brain.respond(to: "ねえ先生、割合がわかんない") {
///     tts.speak(sentence)
/// }
/// // 割り込まれたら: ストリームを止めて、再生できた文字数で切り詰める
/// await brain.cancel()
/// await brain.truncateLastReply(toCharacterCount: playedCount)
/// // 「要確認」のフラグ（flag_for_parent）はセッションに記録される
/// let flags = await brain.sessionFlags
/// ```
actor TeacherBrain {
    static let claudePath = "/v1/claude"
    /// ツールを呼んだあとに返事を続けてもらう回数の上限。
    static let maxToolContinuations = 1
    /// tool_result に入れる文。子どもには聞こえない。
    static let toolResultText = "記録しました。子どもには伝えずに、会話を続けてください。もう話したことはくり返さない。まだ親に話すよう勧めていなければ、「お父さんかお母さんに話してみよう」と短くやさしく伝えてください。もう伝えていれば、何も言わなくてかまいません。"
    /// 黒板に図を出したときの tool_result。
    static let boardResultText = "黒板に図を出しました（子どもに見えています）。もう話したことはくり返さずに、図を見ながら答えられる短い問いかけを1つだけ言ってください。もう問いかけで終えていれば、何も言わなくてかまいません。"
    /// 図を見せる前に子どもが話し始めて、返事を止めたときの tool_result（割り込みのあとで書き換える）。
    static let boardNotShownText = "図を見せる前に子どもが話し始めたので、図は出していません。黒板にはふれずに会話を続けてください。"
    /// 黒板の図を読めなかったときの tool_result。
    static let boardFailedText = "図を出せませんでした。黒板にはふれずに、言葉だけで会話を続けてください。"

    private let client: WorkerClient
    private(set) var systemPrompt: String
    let model: ClaudeModel
    let maxTokens: Int
    let tools: [ToolDefinition]
    /// Anthropic 側で動くツール（web_search）
    let serverTools: [JSONValue]
    /// 参考の写真を探す（#116）
    let imageFinder: (any ReferenceImageFinding)?
    /// 検索を受け付けてもらえなかったので、このセッションでは検索なしで話す
    private(set) var isSearchUnavailable = false
    private(set) var history = ConversationHistory()
    /// このセッションで記録した「要確認」など（spec §3④）。保存は #25 / #28。
    private(set) var sessionFlags = SessionFlags()
    private var currentTask: Task<Void, Never>?

    init(
        client: WorkerClient,
        systemPrompt: String,
        model: ClaudeModel = .haiku,
        maxTokens: Int = 1024,
        tools: [ToolDefinition] = [],
        serverTools: [JSONValue] = [],
        imageFinder: (any ReferenceImageFinding)? = nil
    ) {
        self.client = client
        self.systemPrompt = systemPrompt
        self.model = model
        self.maxTokens = maxTokens
        self.tools = tools
        self.serverTools = serverTools
        self.imageFinder = imageFinder
    }

    /// 問題の答えを探す写真を出さないための見張り（返事ごとに、今の問題のものを入れる）
    private var imageGuard: AnswerLeakGuard?

    func setImageGuard(_ guardian: AnswerLeakGuard?) {
        imageGuard = guardian
    }

    /// システムプロンプトを差し替える（先生のメモ・モードの切り替えなど）。次の呼び出しから効く。
    func setSystemPrompt(_ prompt: String) {
        systemPrompt = prompt
    }

    /// 子どもの発話に返事をする。先生の返事を文ごとに流す（黒板の図は流さない）。
    /// 受け取った文字は届いたそばから履歴に入るので、途中で止めても履歴には途中までが残る。
    func respond(to userText: String) -> AsyncThrowingStream<String, Error> {
        let outputs = respondWithBoards(to: userText)
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        let task = Task {
            do {
                for try await output in outputs {
                    if case .sentence(let sentence) = output { continuation.yield(sentence) }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// 子どもの発話に返事をする。文と、黒板の図（show_board を呼んだとき）を届いた順に流す。
    /// 割り込みで捨てる返事の図も一緒に捨てられるよう、文と同じ流れに入れる。
    func respondWithBoards(to userText: String) -> AsyncThrowingStream<TeacherOutput, Error> {
        currentTask?.cancel()
        history.appendUser(userText)
        let (stream, continuation) = AsyncThrowingStream<TeacherOutput, Error>.makeStream()
        let task = Task {
            do {
                try await self.run(into: continuation)
                continuation.finish()
            } catch {
                // 割り込みで止めたときはエラーにせず、静かに終える
                if Task.isCancelled {
                    continuation.finish()
                } else {
                    continuation.finish(throwing: error)
                }
            }
        }
        currentTask = task
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// 返事のストリームを止める（割り込み）。
    func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }

    /// 割り込み用：最後の返事を、実際に再生した文字数で切り詰める（図をはさんだ前後の文をまたいで数える）。
    func truncateLastReply(toCharacterCount count: Int) {
        history.truncateLastReply(toCharacterCount: count)
    }

    /// 割り込み用：最後の返事の図を、子どもに見せる前に止めた。tool_result を「見せていない」に書き換える
    /// （tool_use は消さずに対を保つ。「黒板に図を出しました」のままだと、次の返事が見えていない図の話をする）
    func markLastReplyBoardsNotShown() {
        history.rewriteLastReplyToolResults { name, content in
            (BoardTools.isBoardTool(name) || name == ReferenceImageTool.name) && content == Self.boardResultText
                ? Self.boardNotShownText : content
        }
    }

    /// 先生から話しかけた発言（定型句・時間での声かけなど）を履歴に残す。
    func recordTeacherUtterance(_ text: String) {
        history.appendAssistantText(text)
    }

    /// 返事をせずに子どもの発話だけを履歴に残す（先生への発話ではなかったときなど）。
    func recordUserUtterance(_ text: String) {
        history.appendUser(text)
    }

    func resetHistory() {
        history.removeAll()
    }

    func resetSessionFlags() {
        sessionFlags.removeAll()
    }

    /// 今の履歴とシステムプロンプトから、Worker に送る本文を作る。
    func makeRequest() -> MessagesRequest {
        var messages = history.messages
        // API は最初のメッセージが user である必要がある（先生から話しかけて始めた場合）
        if messages.first?.role == .assistant {
            messages.insert(ChatMessage(role: .user, content: [.text("（勉強スタート）")]), at: 0)
        }
        return MessagesRequest(
            model: model, maxTokens: maxTokens, system: systemPrompt, messages: messages, stream: true,
            tools: tools.isEmpty ? nil : tools, serverTools: isSearchUnavailable ? [] : serverTools, thinking: MessagesRequest.thinkingDisabled, cachesPrompt: true
        )
    }

    /// 1回の返事。ツールだけ呼んで言葉がなかったときは、tool_result を付けてもう一度呼ぶ。
    private func run(into continuation: AsyncThrowingStream<TeacherOutput, Error>.Continuation) async throws {
        var continuations = 0
        while true {
            try Task.checkCancellation()
            let turn: TurnResult
            do {
                turn = try await streamOnce(makeRequest(), into: continuation)
            } catch where shouldRetryWithoutSearch(error) {
                // 検索の設定を断られても、会話は止めない（許可リストのサイトがクロールを断ったときなど、リクエスト全体が 400 になる）
                isSearchUnavailable = true
                continue
            }
            // 図を出したら、話していても続きを1回もらう（図を見ながらの問いかけで締める）。
            // 続きのリクエストは、それまでの文を読み上げている間に走るので、待ち時間は増えない
            guard turn.calledTools, !turn.spokeText || turn.shownBoard || turn.missedImage || turn.flaggedParent, continuations < Self.maxToolContinuations else { return }
            continuations += 1
        }
    }

    /// 検索つきのリクエストそのものを断られたときだけ true（話し始める前に届く 400）
    private func shouldRetryWithoutSearch(_ error: any Error) -> Bool {
        guard !serverTools.isEmpty, !isSearchUnavailable else { return false }
        switch error {
        case WorkerError.http(let status, _): return status == 400
        case TeacherBrainError.api(let type, _): return type == "invalid_request_error"
        default: return false
        }
    }

    private struct TurnResult {
        var spokeText = false
        var calledTools = false
        var shownBoard = false
        /// 写真が見つからなかった（話していても、言葉や図でのつなぎをもらう）
        var missedImage = false
        /// 親への「要確認」を残した（話していても続きをもらう。親に話すよう勧める言葉が抜けることがあるため）
        var flaggedParent = false
    }

    private func streamOnce(
        _ request: MessagesRequest,
        into continuation: AsyncThrowingStream<TeacherOutput, Error>.Continuation
    ) async throws -> TurnResult {
        let parser = ClaudeStreamParser()
        var splitter = SentenceSplitter()
        var toolUses = ToolUseAccumulator()
        var serverToolIndexes = Set<Int>()
        var lastQuery = ""
        var result = TurnResult()
        let lines = try await client.streamLines(path: Self.claudePath, body: request)
        for try await line in lines {
            try Task.checkCancellation()
            guard let event = parser.parse(line: line) else { continue }
            switch event {
            case .textDelta(_, let text):
                history.appendAssistantText(text)
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.spokeText = true }
                for sentence in splitter.append(text) { continuation.yield(.sentence(sentence)) }
            case .toolUseStart(let index, let id, let name):
                toolUses.start(index: index, id: id, name: name)
            case .serverToolUseStart(let index, let id, let name):
                // 調べている間も黙らないよう、前の文（ちょっと調べてみるね）は結果を待たずに流す
                for sentence in splitter.flush() { continuation.yield(.sentence(sentence)) }
                toolUses.start(index: index, id: id, name: name)
                serverToolIndexes.insert(index)
            case .webSearchResult(_, let results, let errorCode):
                // 暗号化された本文は大きいので履歴に残さない。話した言葉だけが残る
                continuation.yield(.research(ResearchUpdate(results: results, errorCode: errorCode, query: lastQuery)))
            case .inputJSONDelta(let index, let partialJSON):
                toolUses.append(index: index, partialJSON: partialJSON)
            case .contentBlockStop(let index):
                if serverToolIndexes.remove(index) != nil {
                    if let toolUse = toolUses.stop(index: index), toolUse.name == WebSearchTool.name {
                        lastQuery = WebSearchTool.query(from: toolUse.input)
                        continuation.yield(.research(.searching(query: lastQuery)))
                    }
                } else if let toolUse = toolUses.stop(index: index) {
                    if toolUse.name == ReferenceImageTool.name {
                        // 探している間も黙らないよう、前の文（写真を探してみるね）は先に流す
                        for sentence in splitter.flush() { continuation.yield(.sentence(sentence)) }
                        let shown = try await showReferenceImage(toolUse, into: continuation)
                        result.calledTools = true
                        if shown { result.shownBoard = true } else { result.missedImage = true }
                        continue
                    }
                    // 図より前の文は先に流す（話している文と図の順番をそろえる）
                    if BoardTools.isBoardTool(toolUse.name) {
                        for sentence in splitter.flush() { continuation.yield(.sentence(sentence)) }
                    }
                    if let board = handle(toolUse) {
                        continuation.yield(.board(board))
                        result.shownBoard = true
                    }
                    if toolUse.name == ParentFlagTool.name { result.flaggedParent = true }
                    result.calledTools = true
                }
            case .error(let type, let message):
                throw TeacherBrainError.api(type: type, message: message)
            case .messageStop:
                for sentence in splitter.flush() { continuation.yield(.sentence(sentence)) }
                return result
            default:
                break
            }
        }
        // 止められて終わったときは、途中の文を流さない
        try Task.checkCancellation()
        // message_stop が来ずに終わった場合も残りを流す
        for sentence in splitter.flush() { continuation.yield(.sentence(sentence)) }
        return result
    }

    /// 参考の写真を探して流す。見つけて流したら true。
    ///
    /// 探している間に割り込まれても履歴の順番が崩れないよう、tool_use と仮の結果（見せていない）を先に入れてから待つ
    private func showReferenceImage(
        _ toolUse: ToolUseAccumulator.ToolUse,
        into continuation: AsyncThrowingStream<TeacherOutput, Error>.Continuation
    ) async throws -> Bool {
        history.append(.assistant, .toolUse(id: toolUse.id, name: toolUse.name, input: toolUse.input))
        history.append(.user, .toolResult(toolUseID: toolUse.id, content: Self.boardNotShownText))
        guard let imageFinder, let request = ReferenceImageTool.parse(toolUse.input) else {
            history.setToolResult(toolUseID: toolUse.id, content: ReferenceImageTool.notFoundText)
            return false
        }
        // 答えそのものの写真は探さない（探す言葉が答えと同じなら、子どもには何も見せない）
        if case .blocked? = imageGuard?.check(request.query) {
            history.setToolResult(toolUseID: toolUse.id, content: ReferenceImageTool.answerBlockedText)
            return false
        }
        continuation.yield(.research(.searchingImage(query: request.query)))
        let image = await imageFinder.find(query: request.query, caption: request.caption)
        try Task.checkCancellation()
        guard let image else {
            history.setToolResult(toolUseID: toolUse.id, content: ReferenceImageTool.notFoundText)
            continuation.yield(.research(.missedImage(query: request.query)))
            return false
        }
        history.setToolResult(toolUseID: toolUse.id, content: Self.boardResultText)
        continuation.yield(.research(.foundImage(query: request.query)))
        continuation.yield(.board(.referenceImage(image)))
        return true
    }

    /// ツールの呼び出しを処理し、履歴に tool_use と tool_result を残す（API は対になっていないと受け付けない）。
    /// 黒板の図なら、出す中身を返す（読めなかった図は出さない。「図をうまく出せなかった」より、言葉だけの方がよい）。
    private func handle(_ toolUse: ToolUseAccumulator.ToolUse) -> BoardContent? {
        history.append(.assistant, .toolUse(id: toolUse.id, name: toolUse.name, input: toolUse.input))
        switch toolUse.name {
        case ParentFlagTool.name:
            if let flag = ParentFlagTool.parse(toolUse.input) {
                sessionFlags.record(flag)
            }
            history.append(.user, .toolResult(toolUseID: toolUse.id, content: Self.toolResultText))
            return nil
        case let name where BoardTools.isBoardTool(name):
            let content = BoardTools.content(toolName: name, input: toolUse.input)
            if case .text = content {
                history.append(.user, .toolResult(toolUseID: toolUse.id, content: Self.boardFailedText))
                return nil
            }
            history.append(.user, .toolResult(toolUseID: toolUse.id, content: Self.boardResultText))
            return content
        default:
            history.append(.user, .toolResult(toolUseID: toolUse.id, content: "未対応のツールです。"))
            return nil
        }
    }
}
