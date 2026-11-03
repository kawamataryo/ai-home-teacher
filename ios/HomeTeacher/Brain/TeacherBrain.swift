import Foundation

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
    static let toolResultText = "記録しました。子どもには伝えずに、会話を続けてください。"

    private let client: WorkerClient
    private(set) var systemPrompt: String
    let model: ClaudeModel
    let maxTokens: Int
    let tools: [ToolDefinition]
    private(set) var history = ConversationHistory()
    /// このセッションで記録した「要確認」など（spec §3④）。保存は #25 / #28。
    private(set) var sessionFlags = SessionFlags()
    private var currentTask: Task<Void, Never>?

    init(
        client: WorkerClient,
        systemPrompt: String,
        model: ClaudeModel = .haiku,
        maxTokens: Int = 512,
        tools: [ToolDefinition] = []
    ) {
        self.client = client
        self.systemPrompt = systemPrompt
        self.model = model
        self.maxTokens = maxTokens
        self.tools = tools
    }

    /// システムプロンプトを差し替える（先生のメモ・モードの切り替えなど）。次の呼び出しから効く。
    func setSystemPrompt(_ prompt: String) {
        systemPrompt = prompt
    }

    /// 子どもの発話に返事をする。先生の返事を文ごとに流す。
    /// 受け取った文字は届いたそばから履歴に入るので、途中で止めても履歴には途中までが残る。
    func respond(to userText: String) -> AsyncThrowingStream<String, Error> {
        currentTask?.cancel()
        history.appendUser(userText)
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
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

    /// 割り込み用：最後の先生の発言を、実際に再生した文字数で切り詰める。
    func truncateLastReply(toCharacterCount count: Int) {
        history.truncateLastAssistant(toCharacterCount: count)
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
            tools: tools.isEmpty ? nil : tools, thinking: MessagesRequest.thinkingDisabled
        )
    }

    /// 1回の返事。ツールだけ呼んで言葉がなかったときは、tool_result を付けてもう一度呼ぶ。
    private func run(into continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        var continuations = 0
        while true {
            try Task.checkCancellation()
            let turn = try await streamOnce(makeRequest(), into: continuation)
            guard turn.calledTools, !turn.spokeText, continuations < Self.maxToolContinuations else { return }
            continuations += 1
        }
    }

    private struct TurnResult {
        var spokeText = false
        var calledTools = false
    }

    private func streamOnce(
        _ request: MessagesRequest,
        into continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws -> TurnResult {
        let parser = ClaudeStreamParser()
        var splitter = SentenceSplitter()
        var toolUses = ToolUseAccumulator()
        var result = TurnResult()
        let lines = try await client.streamLines(path: Self.claudePath, body: request)
        for try await line in lines {
            try Task.checkCancellation()
            guard let event = parser.parse(line: line) else { continue }
            switch event {
            case .textDelta(_, let text):
                history.appendAssistantText(text)
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.spokeText = true }
                for sentence in splitter.append(text) { continuation.yield(sentence) }
            case .toolUseStart(let index, let id, let name):
                toolUses.start(index: index, id: id, name: name)
            case .inputJSONDelta(let index, let partialJSON):
                toolUses.append(index: index, partialJSON: partialJSON)
            case .contentBlockStop(let index):
                if let toolUse = toolUses.stop(index: index) {
                    handle(toolUse)
                    result.calledTools = true
                }
            case .error(let type, let message):
                throw TeacherBrainError.api(type: type, message: message)
            case .messageStop:
                for sentence in splitter.flush() { continuation.yield(sentence) }
                return result
            default:
                break
            }
        }
        // 止められて終わったときは、途中の文を流さない
        try Task.checkCancellation()
        // message_stop が来ずに終わった場合も残りを流す
        for sentence in splitter.flush() { continuation.yield(sentence) }
        return result
    }

    /// ツールの呼び出しを処理し、履歴に tool_use と tool_result を残す（API は対になっていないと受け付けない）。
    private func handle(_ toolUse: ToolUseAccumulator.ToolUse) {
        history.append(.assistant, .toolUse(id: toolUse.id, name: toolUse.name, input: toolUse.input))
        switch toolUse.name {
        case ParentFlagTool.name:
            if let flag = ParentFlagTool.parse(toolUse.input) {
                sessionFlags.record(flag)
            }
            history.append(.user, .toolResult(toolUseID: toolUse.id, content: Self.toolResultText))
        default:
            history.append(.user, .toolResult(toolUseID: toolUse.id, content: "未対応のツールです。"))
        }
    }
}
