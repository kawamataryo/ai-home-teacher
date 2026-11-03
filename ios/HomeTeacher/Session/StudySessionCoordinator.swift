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
        /// 設定画面の値（話している間のマイクの扱い・カメラ）。始めるときに読む
        var preferences: SessionPreferences?
        /// カメラ（#15）。nil なら撮影しない
        var camera: (any PhotoCapturing)?
        var countdown: (any CountdownPlaying)?
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
    /// 撮る前のひと言（定型句なので待たずに話せる）
    static let captureLead = "どれどれ"
    /// 見せたいとはっきり言う言い方
    static let lookPhrases = ["見て", "みて", "見せ", "みせ"]
    /// 分析を待つ間（定型句）
    static let analysisFiller = "ちょっと考えるね"
    /// 写真を分析したあと、返事を作るときに子どもの発話のかわりに送る文
    static let photoShownTrigger = "（ノートの写真を先生に見せた）"
    static let captureFailedLine = "ごめん、うまく撮れなかった。もう一回見せてくれる？"
    static let analysisFailedLine = "ごめん、写真がよく見えなかった。もう一回撮ってみようか？"

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
    /// 撮影から分析までの間
    private(set) var isCapturing = false
    /// 撮る前のカウントダウンの数（3, 2, 1）
    private(set) var captureCountdown: Int?
    /// 撮影できるか（カメラがある）
    var canCapture: Bool { deps.camera?.isAvailable == true }
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
    /// 割り込まれた返事の履歴の切り詰め（次の返事はこれを待つ）
    @ObservationIgnored private var truncation: Task<Void, Never>?
    /// ConversationController に渡す声。いまの返事で何を話したかを数える
    @ObservationIgnored private let tracker: SpokenReplyTracker
    @ObservationIgnored private var sessionID = UUID().uuidString
    @ObservationIgnored private(set) var sessionStartedAt: Date?
    /// 先生のメモ（#15 の分析結果）。プロンプトを組み直すときにも入れる
    @ObservationIgnored private(set) var teacherNote: String?
    /// このセッションで取り組んだ問題（ふり返りに渡す）
    @ObservationIgnored private(set) var problems: [ProblemRecord] = []
    /// いま一緒に取り組んでいる問題（分析の結果・ヒントの段階・答え漏れの検査）
    @ObservationIgnored private(set) var tutoring: TutoringState?
    @ObservationIgnored private var captureJudge: (any CaptureRequestJudge)?

    init(dependencies: Dependencies) {
        self.deps = dependencies
        self.tracker = SpokenReplyTracker(voice: dependencies.voice)
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
        tutoring = nil
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

        if let preferences = deps.preferences {
            settings.conversation.speakingInputMode = preferences.speakingInputMode
        }
        let conversation = settings.conversation
        trace("話している間のマイク: \(conversation.speakingInputMode == .bargeIn ? "開いたまま（割り込み）" : "止める")")
        var endDecider: (any EndOfUtteranceDecider)?
        if let decisions = deps.decisions {
            let judge = JevAddressingJudge(decisions: decisions, fallback: CallWordAddressingJudge(callWords: conversation.callWords))
            addressingJudge = judge
            endDecider = JevEndOfUtteranceDecider(decisions: decisions)
            captureJudge = JevCaptureRequestJudge(decisions: decisions)
        } else {
            addressingJudge = nil
            captureJudge = CaptureRequestDetector()
        }
        let controller = ConversationController(
            input: deps.input, output: tracker, clock: deps.clock, settings: conversation,
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
            await noteTutoringTurn(text)
            startReply(to: text, fallback: Self.replyFallback, captureCheck: captureCheck(for: text))
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
    ///
    /// 履歴は「実際に話したところ」で切り詰める（#13）。順番は
    /// 1. 声を止めて、いまの文の何文字目まで話したかを受け取る（止めたあとは再生位置が取れない）
    /// 2. TeacherBrain のストリームを止める（止める前に切ると、あとから届いた文字が足されてしまう）
    /// 3. 履歴を読んで切り詰める
    @discardableResult
    private func dropInFlightReply() async -> Bool {
        guard let inFlight = inFlightReply, inFlight == replyGeneration else { return false }
        replyGeneration += 1
        inFlightReply = nil
        // 1 から snapshot までの間に await をはさまない（話している文の後片付けが先に走らないように）
        let played = deps.voice.stop()
        let spoken = tracker.snapshot(playedInCurrent: played)
        tracker.invalidate()
        avatar.send(.userStartedSpeaking)
        guard let brain else { return true }
        let task = Task { [weak self] in
            await brain.cancel()
            let messages = await brain.history.messages
            guard let count = ReplyTruncation.targetCount(messages: messages, spoken: spoken) else { return }
            await brain.truncateLastReply(toCharacterCount: count)
            self?.trace("割り込まれたので履歴を \(count) 文字に切り詰めた（話し終えた文 \(spoken.finished.count)・途中の文 \(spoken.playedInCurrent) 文字）")
        }
        truncation = task
        await task.value
        return true
    }

    /// 返事を作り始める。1 文目が届くまでは考え中のまま
    ///
    /// `captureCheck` があれば（撮影の依頼かを Jev / 規則で判定中）、1 文目を話す前に答えを待ち、
    /// 撮影の依頼なら返事を捨てて撮影に移る（判定と返事の生成を並べて、待ち時間を増やさない）
    private func startReply(to text: String, fallback: String, captureCheck: Task<Bool, Never>? = nil) {
        replyGeneration += 1
        let generation = replyGeneration
        // 割り込みが返事のタスクより先に来ても捨てられるよう、ここで印を付ける
        inFlightReply = generation
        replyTask = Task { [weak self] in
            await self?.runReply(to: text, fallback: fallback, generation: generation, captureCheck: captureCheck)
        }
    }

    private func runReply(to text: String, fallback: String, generation: Int, captureCheck: Task<Bool, Never>?) async {
        guard let brain, let controller else { return }
        defer { if inFlightReply == generation { inFlightReply = nil } }
        // 前の返事の切り詰めが終わってから、新しい発話を履歴に足す
        await truncation?.value
        guard generation == replyGeneration else { return }
        tracker.beginReply()
        let acceptedAt = deps.clock.now
        lastReplyLatency = nil
        let stream = await brain.respond(to: text)
        let (sentences, continuation) = AsyncStream<String>.makeStream()
        var speakTask: Task<SpeakOutcome, Never>?
        var spoken: [String] = []
        /// 読み上げる前の文（答え漏れで差し替える前）。履歴の位置を出すのに使う
        var originals: [String] = []
        var blockedReplacement: String?
        var wantsCapture = false
        var failure: (any Error)?
        do {
            for try await sentence in stream {
                guard generation == replyGeneration else { break }
                if speakTask == nil, let captureCheck, await captureCheck.value {
                    wantsCapture = true
                    break
                }
                guard generation == replyGeneration else { break }
                // 答えを先に言ってしまう文は、読み上げる前に差し替える（AnswerLeakGuard）
                var line = sentence
                if case .blocked(let replacement)? = tutoring?.leakGuard.check(sentence) {
                    line = replacement
                    blockedReplacement = replacement
                    trace("答えを言いそうな文を差し替えた")
                }
                if speakTask == nil {
                    let latency = deps.clock.now - acceptedAt
                    lastReplyLatency = latency
                    trace("1文目まで \(latency.formatted(.units(allowed: [.milliseconds])))")
                    speakTask = Task { await controller.speak(sentences) }
                }
                spoken.append(line)
                continuation.yield(line)
                if blockedReplacement != nil { break }
                originals.append(sentence)
            }
        } catch {
            failure = error
        }
        continuation.finish()

        if speakTask == nil, !wantsCapture, failure == nil, let captureCheck, generation == replyGeneration {
            wantsCapture = await captureCheck.value
        }
        if wantsCapture, generation == replyGeneration {
            // 作りかけの返事は捨てて撮影へ（子どもの発話は履歴に残し、写真のあとにもう一度返事を作る）
            inFlightReply = nil
            await brain.cancel()
            let messages = await brain.history.messages
            if let count = ReplyTruncation.targetCount(messages: messages, spoken: SpokenSnapshot(finished: [], playedInCurrent: 0)) {
                await brain.truncateLastReply(toCharacterCount: count)
            }
            trace("撮影の依頼とみなした")
            await runCapture()
            return
        }
        if let blockedReplacement {
            // 残りの文（答えの説明が続きやすい）は話さない。履歴も差し替えた文にそろえる
            await brain.cancel()
            let messages = await brain.history.messages
            if let last = messages.last, last.role == .assistant {
                let count = ReplyTruncation.characterCount(
                    in: last.text, spoken: SpokenSnapshot(finished: originals, playedInCurrent: 0)
                )
                await brain.truncateLastReply(toCharacterCount: count)
            }
            await brain.recordTeacherUtterance(blockedReplacement)
        }

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

    // MARK: - 撮影と問題の分析（#15）

    /// 「これ見て」などの撮影の依頼かを判定し始める。カメラがなければ判定しない
    private func captureCheck(for text: String) -> Task<Bool, Never>? {
        guard let judge = captureJudge, deps.camera?.isAvailable == true, !isCapturing else { return nil }
        // 問題を見たあとの「わかんない」はヒントを求める発話。「見て」と言われたときだけ撮り直す
        if tutoring != nil, HelpRequestDetector.isHelpRequest(text),
           !CaptureRequestDetector.matches(text, patterns: Self.lookPhrases) {
            return nil
        }
        return Task { await judge.isCaptureRequest(text) }
    }

    /// 画面の撮影ボタン
    func captureFromButton() async {
        guard phase == .active, !isCapturing, conversationState == .idle else { return }
        await runCapture()
    }

    /// どれどれ → カウントダウン → 撮影 → 縮めて送る（送ったら捨てる）→ 分析 → ヒントの段階と先生のメモ → 黒板 → 返事
    private func runCapture() async {
        guard let camera = deps.camera, let brain, let controller, !isCapturing else { return }
        isCapturing = true
        defer {
            isCapturing = false
            captureCountdown = nil
        }
        avatar.send(.lookAtNotebook)
        let position = deps.preferences?.cameraPosition ?? .back
        let preparing = Task { try await camera.prepare(position: position) }
        await controller.speak(Self.captureLead)
        do {
            try await preparing.value
            await deps.countdown?.countdown(from: 3) { [weak self] in self?.captureCountdown = $0 }
            captureCountdown = nil
            // 写真はこの中だけで持つ。縮めた JPEG も送ったあとは持たない（spec §3②）
            let jpeg = try await Self.capturedJPEG(camera)
            trace("撮影した（\(jpeg.count / 1024)KB）")
            let filler = Task { await controller.speak(Self.analysisFiller) }
            let analyzer = ProblemAnalyzer(client: deps.client, library: deps.library)
            let result = try await analyzer.analyze(jpegData: jpeg, conversation: await brain.history.messages)
            _ = await filler.value
            await applyAnalysis(result)
            avatar.send(.lookAwayFromNotebook)
            guard phase == .active else { return }
            startReply(to: Self.photoShownTrigger, fallback: Self.replyFallback)
        } catch {
            avatar.send(.lookAwayFromNotebook)
            trace("撮影か分析に失敗: \(error)")
            let line = error is CameraError ? Self.captureFailedLine : Self.analysisFailedLine
            await brain.recordTeacherUtterance(line)
            await controller.speak(line)
        }
    }

    /// 撮って、長辺 2048px の JPEG にする
    private static func capturedJPEG(_ camera: any PhotoCapturing) async throws -> Data {
        let photo = try await camera.capture()
        guard let data = ImageResizer.jpegData(from: photo) else { throw CameraError.captureFailed }
        return data
    }

    /// 分析の結果を、ヒントの段階・先生のメモ・黒板・ふり返り用の問題の記録に入れる
    private func applyAnalysis(_ result: AnalysisResult) async {
        let analysis = result.analysis
        var ladder = HintLadder(analysis: analysis)
        // 作文を一緒に組み立てたあとに撮ったなら、書いたものの講評に進む
        if analysis.kind == .writing, tutoring?.ladder.kind == .writing {
            ladder.handle(.submittedWriting)
        }
        tutoring = TutoringState(analysis: analysis, ladder: ladder, leakGuard: AnswerLeakGuard(analysis: analysis))
        problems.append(ProblemRecord(
            kind: analysis.kind, summary: analysis.problemSummary, solvedBySelf: false,
            hintLevelReached: ladder.level, createdAt: deps.now()
        ))
        board = result.boards.first ?? .text(analysis.problemSummary)
        trace("分析した: \(analysis.kind.rawValue)「\(analysis.problemSummary)」黒板 \(result.boards.count) 枚")
        await updateTeacherNote()
    }

    /// 子どもの発話でヒントの段階を進める（答えを自分で言えた・助けを求めた）
    private func noteTutoringTurn(_ text: String) async {
        guard var state = tutoring else { return }
        var changed = false
        if state.leakGuard.noteChildUtterance(text) {
            state.ladder.handle(.solved)
            changed = true
        } else if HelpRequestDetector.isHelpRequest(text) {
            changed = state.ladder.handle(.askedForHelp)
        }
        tutoring = state
        guard changed else { return }
        trace("ヒントの段階: \(state.ladder.level)/\(state.ladder.stages.count)\(state.ladder.isSolved ? "（自分で解けた）" : "")")
        await updateTeacherNote()
    }

    private func updateTeacherNote() async {
        guard let state = tutoring else { return }
        if var last = problems.last {
            last.hintLevelReached = state.ladder.level
            last.solvedBySelf = state.ladder.isSolved
            problems[problems.count - 1] = last
        }
        teacherNote = TeacherNote.make(analysis: state.analysis, ladder: state.ladder)
        await rebuildSystemPrompt()
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
            trace("ふり返りを保存した（Claude: \(finished.usedClaude ? "使えた" : "使えず決まり文句")）")
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

/// いま一緒に取り組んでいる問題
struct TutoringState: Sendable {
    var analysis: ProblemAnalysis
    var ladder: HintLadder
    var leakGuard: AnswerLeakGuard
}
