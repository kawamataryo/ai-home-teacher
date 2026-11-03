import Foundation
import Observation
import OSLog

/// 学習セッションのまとめ役（spec §3①・④）。
/// 名前の `StudySession` は SwiftData のモデル（Memory/MemoryModels.swift）が使っているので、こちらは Coordinator と呼ぶ。
///
/// 持っているもの:
/// - 音声入力（`SpeechInput`）の出来事をここで 1 か所だけ読み、待機中は「勉強スタート」を、
///   セッション中は `ConversationController.handle` に流す（コントローラの `start()` は呼ばない。ストリームの購読者は 1 つだけのため）
/// - セッションごとに作る ConversationController・TeacherBrain・FocusTimer（+ ConversationNudgeSpeaker）
/// - 先生の声（`TeacherSpeaking`）とアバター（`AvatarController`）
/// - 始まりの「前回のこと」（OpeningPromptBuilder）、終わりのふり返り（SessionReflector）、終わったあとの同期（SyncService）
/// - Jev の判定（呼びかけか・言い終わったか）。Jev が使えなければ規則ベース
///
/// 子どもの発話を受け付けたら、TeacherBrain の文を 1 文目が届くまで待ってから `ConversationController.speak` に流す
/// （それまでは「考え中」のまま。アバターも首をかしげたまま）。割り込まれたら作りかけの応答を捨てる（#10 の注意）。
@MainActor
@Observable
final class StudySessionCoordinator {
    enum Phase: Equatable, Sendable {
        /// セッションの外。マイクは開いていて「勉強スタート」を待つ
        case idle
        /// 始めている（前回のことを読んで、最初のひと言を作っている）
        case starting
        case active
        /// 終えている（ふり返りを作って話し、保存・同期している）
        case ending
    }

    /// セッションごとに変えられる設定。始めるときに読む
    struct Settings: Equatable, Sendable {
        var conversation = ConversationSettings()
        var timer = FocusTimerSettings()
    }

    /// 外から渡すもの。テストではモックに差し替える
    struct Dependencies {
        var client: WorkerClient
        var input: any SpeechInput
        var voice: any TeacherSpeaking
        var store: any MemoryStore
        var sync: (any SessionSyncing)?
        var clock: any ConversationClock = SystemConversationClock()
        var library = PromptLibrary()
        /// Jev（TypeSafe AI）。nil なら規則ベースだけで判定する
        var decisions: TeacherDecisions?
        var now: @Sendable () -> Date = { Date() }
    }

    /// 最初のひと言を作れなかったときの決まり文句
    static let openingFallback = "よし、始めよう！今日は何からやる？"
    /// 返事を作れなかったとき（通信の失敗など）。定型句なので待たずに話せる
    static let replyFallback = "もう一回言ってみて"
    /// ふり返りを作っている間に話す
    static let reflectionFiller = "今日もおつかれさま。ちょっとふり返るね。"
    /// 最初のひと言を作るときに、子どもの発話のかわりに送る文
    static let openingTrigger = "（勉強スタート）"

    // MARK: - 画面に出すもの

    private(set) var phase: Phase = .idle
    private(set) var conversationState: ConversationState = .idle
    /// 子どもが話したことの字幕（小さく出す）
    private(set) var caption = ""
    /// 黒板の中身（#15 の分析で出す）
    private(set) var board: BoardContent?
    private(set) var sessionMode: SessionMode = .study
    private(set) var timer: FocusTimer?
    private(set) var statusMessage: String?
    let avatar = AvatarController()
    var settings = Settings()

    // MARK: - 記録（実機の自己テスト・遅延の計測用）

    /// 受け付けてから 1 文目が届くまで
    private(set) var lastReplyLatency: Duration?
    /// 最後の返事を Worker（Claude）から受け取れたか
    private(set) var lastReplyFromWorker: Bool?
    /// 最後の返事で話した文
    private(set) var lastReplySentences: [String] = []
    /// 話し終えた（または割り込まれた）返事の数。決まり文句で代わりにしたものも数える
    private(set) var completedReplies = 0
    private(set) var traceLines: [String] = []
    /// 記録を 1 行出すたびに呼ぶ（自己テストがファイルに書く）
    @ObservationIgnored var onTrace: ((String) -> Void)?

    // MARK: - 中身

    @ObservationIgnored private let deps: Dependencies
    @ObservationIgnored private let openingBuilder: OpeningPromptBuilder
    @ObservationIgnored private let logger = Logger(subsystem: "com.kawamataryo.HomeTeacher", category: "StudySession")
    @ObservationIgnored private var inputTask: Task<Void, Never>?
    @ObservationIgnored private var controllerEventsTask: Task<Void, Never>?
    @ObservationIgnored private var timerEventsTask: Task<Void, Never>?
    @ObservationIgnored private var replyTask: Task<Void, Never>?
    @ObservationIgnored private var captionClear: (any ScheduledAction)?

    @ObservationIgnored private(set) var controller: ConversationController?
    @ObservationIgnored private(set) var brain: TeacherBrain?
    @ObservationIgnored private var nudgeSpeaker: ConversationNudgeSpeaker?
    @ObservationIgnored private var addressingJudge: JevAddressingJudge?
    /// 返事ごとに増やす。割り込み・終了のあとで古い返事を話さないようにする
    @ObservationIgnored private var replyGeneration = 0
    /// 作っている途中・話している途中の返事の世代。なければ nil
    @ObservationIgnored private var inFlightReply: Int?
    @ObservationIgnored private var sessionID = UUID().uuidString
    @ObservationIgnored private(set) var sessionStartedAt: Date?
    /// 先生のメモ（#15 の分析結果）。プロンプトを組み直すときにも入れる
    @ObservationIgnored private(set) var teacherNote: String?
    /// このセッションで取り組んだ問題（ふり返りに渡す）
    @ObservationIgnored private(set) var problems: [ProblemRecord] = []

    init(dependencies: Dependencies) {
        self.deps = dependencies
        self.openingBuilder = OpeningPromptBuilder(library: dependencies.library)
    }

    // MARK: - 聞き取り

    /// 音声入力の出来事を読み始める（画面を開いたときに 1 回）
    func listen() {
        guard inputTask == nil else { return }
        let stream = deps.input.events
        inputTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.handleInput(event)
            }
        }
    }

    private func handleInput(_ event: SpeechInputEvent) {
        if case .transcript(let text) = event { showCaption(text) }
        switch phase {
        case .idle:
            if case .transcript(let text) = event, VoiceCommand.parse(text) == .start {
                trace("「\(text)」を聞き取ったので始める")
                // コマンドの文字を、セッションの最初の発話に持ち越さない
                (deps.input as? any UtteranceDiscarding)?.discardCurrentUtterance()
                Task { await self.start() }
            }
        case .active:
            controller?.handle(event)
        case .starting, .ending:
            break
        }
    }

    // MARK: - 始まり

    /// セッションを始める（大きなボタン、または「勉強スタート」）
    func start() async {
        guard phase == .idle else { return }
        phase = .starting
        statusMessage = nil
        sessionID = UUID().uuidString
        sessionStartedAt = deps.now()
        sessionMode = .study
        teacherNote = nil
        problems = []
        board = nil
        lastReplySentences = []
        trace("セッション開始")

        let systemPrompt: String
        do {
            systemPrompt = try await openingBuilder.conversationSystemPrompt(store: deps.store, mode: .study, now: deps.now())
        } catch {
            trace("前回のことを読めなかった: \(error)")
            systemPrompt = (try? deps.library.conversationSystemPrompt(mode: .study)) ?? ""
        }
        let brain = TeacherBrain(
            client: deps.client, systemPrompt: systemPrompt, tools: (try? deps.library.conversationTools()) ?? []
        )
        self.brain = brain

        let conversation = settings.conversation
        var endDecider: (any EndOfUtteranceDecider)?
        if let decisions = deps.decisions {
            let judge = JevAddressingJudge(decisions: decisions, fallback: CallWordAddressingJudge(callWords: conversation.callWords))
            addressingJudge = judge
            endDecider = JevEndOfUtteranceDecider(decisions: decisions)
        } else {
            addressingJudge = nil
        }
        let controller = ConversationController(
            input: deps.input, output: deps.voice, clock: deps.clock, settings: conversation,
            addressingJudge: addressingJudge, endOfUtteranceDecider: endDecider
        )
        self.controller = controller
        conversationState = controller.state
        observeConversationState()
        controllerEventsTask = Task { [weak self] in
            for await event in controller.events {
                guard let self else { return }
                await self.handleConversation(event)
            }
        }

        let nudgeSpeaker = ConversationNudgeSpeaker(controller: controller)
        self.nudgeSpeaker = nudgeSpeaker
        let timer = FocusTimer(clock: deps.clock, settings: settings.timer, nudgeSink: nudgeSpeaker)
        self.timer = timer
        timerEventsTask = Task { [weak self] in
            for await event in timer.events {
                guard let self else { return }
                await self.handleTimer(event)
            }
        }

        phase = .active
        timer.start()
        startReply(to: Self.openingTrigger, fallback: Self.openingFallback)
    }

    // MARK: - 会話

    private func handleConversation(_ event: ConversationEvent) async {
        switch event {
        case .userTurnAccepted(let text):
            trace("受け付けた発話: 「\(text)」")
            if VoiceCommand.parse(text) == .end {
                // このタスク（出来事の読み取り）は終わるときに止めるので、別のタスクで終える
                Task { await self.end() }
                return
            }
            startReply(to: text, fallback: Self.replyFallback)
        case .utteranceIgnored(let text):
            trace("先生への発話ではないとみなした: 「\(text)」")
            if VoiceCommand.parse(text) == .end { Task { await self.end() } }
        case .bargeIn(let during):
            trace("割り込み（\(during == .speaking ? "発話中" : "考え中")）")
            await handleBargeIn()
        }
    }

    /// 割り込まれた: 作りかけの応答を捨て、声とストリームを止める
    private func handleBargeIn() async {
        if await dropInFlightReply() { return }
        // 返事ではない発話（時間での声かけなど）の途中だった
        deps.voice.stop()
    }

    /// 作っている途中・話している途中の返事を捨てる。捨てたら true（割り込みと、状態の見張りの両方から呼ばれるので 1 回だけ効く）
    @discardableResult
    private func dropInFlightReply() async -> Bool {
        guard let inFlight = inFlightReply, inFlight == replyGeneration else { return false }
        replyGeneration += 1
        inFlightReply = nil
        // 止める前に数える（止めると再生位置が取れなくなる）。ここから await までの間に他の処理は入らない
        deps.voice.stop()
        await brain?.cancel()
        return true
    }

    /// 返事を作り始める。1 文目が届くまでは考え中のまま
    private func startReply(to text: String, fallback: String) {
        replyGeneration += 1
        let generation = replyGeneration
        replyTask = Task { [weak self] in
            await self?.runReply(to: text, fallback: fallback, generation: generation)
        }
    }

    private func runReply(to text: String, fallback: String, generation: Int) async {
        guard let brain, let controller else { return }
        inFlightReply = generation
        defer { if inFlightReply == generation { inFlightReply = nil } }
        let acceptedAt = deps.clock.now
        lastReplyLatency = nil
        let stream = await brain.respond(to: text)
        let (sentences, continuation) = AsyncStream<String>.makeStream()
        var speakTask: Task<SpeakOutcome, Never>?
        var spoken: [String] = []
        var failure: (any Error)?
        do {
            for try await sentence in stream {
                guard generation == replyGeneration else { break }
                if speakTask == nil {
                    let latency = deps.clock.now - acceptedAt
                    lastReplyLatency = latency
                    trace("1文目まで \(latency.formatted(.units(allowed: [.milliseconds])))")
                    speakTask = Task { await controller.speak(sentences) }
                }
                spoken.append(sentence)
                continuation.yield(sentence)
            }
        } catch {
            failure = error
        }
        continuation.finish()

        if speakTask == nil {
            // 1 文も話さなかった
            guard generation == replyGeneration, phase == .active else { return }
            lastReplyFromWorker = false
            trace("返事を作れなかった: \(failure.map { String(describing: $0) } ?? "空の返事")")
            await brain.recordTeacherUtterance(fallback)
            await controller.speak(fallback)
            completedReplies += 1
            return
        }
        if let failure { trace("返事の途中で止まった: \(failure)") }
        lastReplyFromWorker = true
        lastReplySentences = spoken
        addressingJudge?.teacherLastSaid = spoken.last
        let outcome = await speakTask?.value
        trace("返事: \(spoken.joined()) → \(outcome.map { "\($0)" } ?? "-")")
        completedReplies += 1
    }

    private func handleTimer(_ event: FocusTimerEvent) async {
        guard case .phaseStarted(let next) = event else { return }
        let mode: SessionMode = next == .rest ? .rest : .study
        guard mode != sessionMode else { return }
        sessionMode = mode
        avatar.send(mode == .rest ? .breakStarted : .breakEnded)
        trace(mode == .rest ? "休憩に入った（雑談モード）" : "休憩が終わった（勉強モード）")
        await rebuildSystemPrompt()
    }

    /// モードや先生のメモが変わったら、前回のことも含めてプロンプトを組み直す（OpeningPromptBuilder を通す）
    func rebuildSystemPrompt() async {
        guard let brain else { return }
        do {
            let prompt = try await openingBuilder.conversationSystemPrompt(
                store: deps.store, mode: sessionMode, teacherNote: teacherNote, now: deps.now()
            )
            await brain.setSystemPrompt(prompt)
        } catch {
            trace("プロンプトを組み直せなかった: \(error)")
        }
    }

    // MARK: - 終わり

    /// セッションを終える（大きなボタン、または「終わり」）。ふり返りを話し、保存して同期する
    func end() async {
        guard phase == .active, let brain, let controller else { return }
        phase = .ending
        trace("セッション終了")
        replyGeneration += 1
        deps.voice.stop()
        await brain.cancel()
        controller.stop()
        let focusMinutes = Self.focusMinutes(timer)
        timer?.stop()
        timerEventsTask?.cancel()
        if sessionMode == .rest { avatar.send(.breakEnded) }

        // ふり返りを作っている間（数秒）は決まり文句でつなぐ
        let filler = Task { await controller.speak(Self.reflectionFiller) }
        let input = SessionReflectionInput(
            sessionID: sessionID,
            startedAt: sessionStartedAt ?? deps.now(),
            endedAt: deps.now(),
            focusMinutes: focusMinutes,
            transcript: await brain.history.messages,
            problems: problems,
            flags: await brain.sessionFlags
        )
        let reflector = SessionReflector(client: deps.client, library: deps.library)
        let closing: String
        do {
            let finished = try await reflector.finish(input, store: deps.store, now: deps.now())
            closing = finished.spokenClosing
            trace("ふり返りを保存した（Claude: \(finished.usedClaude ? "使えた" : "使えず決まり文句")）\(finished.reflectionError.map { " 理由: \($0)" } ?? "")")
        } catch {
            closing = SessionReflector.fallback(for: input).spokenClosing
            trace("セッションを保存できなかった: \(error)")
        }
        _ = await filler.value
        await controller.speak(closing)

        if let sync = deps.sync {
            let report = await sync.syncNow(reason: .sessionEnded)
            trace("同期: \(report.outcome)")
        }
        teardown()
        phase = .idle
    }

    /// 集中した時間（分）。終えた集中 + いまの集中の経過
    static func focusMinutes(_ timer: FocusTimer?) -> Int {
        guard let timer else { return 0 }
        var total = timer.settings.focusDuration * timer.completedFocusCount
        if timer.status != .stopped, timer.phase == .focus {
            total += timer.settings.focusDuration - timer.remaining
        }
        return Int(total.components.seconds / 60)
    }

    private func teardown() {
        controllerEventsTask?.cancel()
        controllerEventsTask = nil
        timerEventsTask = nil
        replyTask = nil
        controller = nil
        nudgeSpeaker = nil
        addressingJudge = nil
        timer = nil
        conversationState = .idle
        sessionMode = .study
    }

    // MARK: - アバター

    /// ConversationController の状態をアバターに伝える（Observation で見張る）
    private func observeConversationState() {
        guard let controller else { return }
        withObservationTracking {
            _ = controller.state
        } onChange: { [weak self] in
            // onChange は値が変わる前に呼ばれるので、MainActor に移ってから読む
            Task { @MainActor [weak self] in
                guard let self, self.controller === controller else { return }
                self.conversationStateChanged(to: controller.state)
                self.observeConversationState()
            }
        }
    }

    private func conversationStateChanged(to next: ConversationState) {
        let previous = conversationState
        guard previous != next else { return }
        conversationState = next
        for event in Self.avatarEvents(from: previous, to: next) { avatar.send(event) }
        // 返事を待っている間（最初のひと言の前など、まだ待機のとき）に話し始めた。割り込みの出来事は出ないので、ここで捨てる
        if next == .listening, inFlightReply == replyGeneration {
            Task { await self.dropInFlightReply() }
        }
    }

    /// 会話の状態の変わり方から、アバターに送るできごと
    static func avatarEvents(from previous: ConversationState, to next: ConversationState) -> [AvatarEvent] {
        switch next {
        case .listening: [.userStartedSpeaking]
        case .thinking: [.thinkingStarted]
        case .speaking: [.speakingStarted(emotion: .neutral)]
        case .idle:
            switch previous {
            case .speaking: [.speakingEnded]
            case .listening: [.userStoppedSpeaking]
            // 考え中から待機に戻る（返事を取りやめた）出来事はないので、聞く → 聞き終わる で休みの姿勢に戻す
            case .thinking: [.userStartedSpeaking, .userStoppedSpeaking]
            case .idle: []
            }
        }
    }

    // MARK: - 表示確認

    /// 表示確認用に、状態を固定して見せる（起動引数 `-sessionPreview`。シミュレーターのスクリーンショット用）
    func showPreview(_ preview: SessionPreviewState) {
        switch preview {
        case .idle:
            phase = .idle
            return
        case .listening, .speaking:
            phase = .active
            let timer = FocusTimer(clock: deps.clock, settings: settings.timer)
            timer.start()
            self.timer = timer
        }
        conversationStateChanged(to: preview == .listening ? .listening : .speaking)
        if preview == .listening {
            caption = "ねえ先生、この割合の問題がよくわかんない"
        } else {
            caption = ""
            board = BoardSamples.content(.stepCards)
        }
    }

    // MARK: - 字幕・記録

    private func showCaption(_ text: String) {
        caption = text
        captionClear?.cancel()
        captionClear = deps.clock.schedule(after: .seconds(6)) { [weak self] in
            guard let self, self.caption == text else { return }
            self.caption = ""
        }
    }

    func trace(_ message: String) {
        logger.info("\(message, privacy: .public)")
        traceLines.append(message)
        if traceLines.count > 200 { traceLines.removeFirst(traceLines.count - 200) }
        onTrace?(message)
    }
}
