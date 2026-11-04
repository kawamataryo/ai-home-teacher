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
        var patience = Patience()
    }

    /// Worker / Claude をどこまで待つか（#66。固まらないように、一定時間で諦めて聞き直す）
    struct Patience: Equatable, Sendable {
        /// 返事の 1 文目がこれまでに届かなければ、定型句（ちょっと考えるね）でつなぐ
        var replyFiller: Duration = .seconds(3)
        /// 返事の流れがこの間止まったら諦める（1 文目まで・途中で止まったときの両方）
        var replyGiveUp: Duration = .seconds(15)
        /// 写真の分析（Sonnet）
        var analysisGiveUp: Duration = .seconds(60)
        /// ふり返り（Sonnet）。過ぎたら決まり文句でふり返る（セッションは保存する）
        var reflectionGiveUp: Duration = .seconds(30)
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
        /// 子どもの答えの判定（#73）。nil なら `decisions` で `AnswerJudge` を作る
        var answerJudge: (any AnswerJudging)?
        /// 見守り（#30）。nil なら見守らない
        var watchOver: (any WatchOverControlling)?
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
    /// Worker / Claude につながらないとき（定型句。端末に音声があるのですぐ話せる）。このあとに聞き直す文を続ける
    static let troubleLine = "ちょっと調子が悪いみたい。"
    /// 返事の 1 文目が遅いときのつなぎ（定型句）
    static let replyFiller = "ちょっと考えるね"
    /// 写真を送れなかったとき（通信の失敗）
    static let analysisOfflineLine = "写真は、あとでもう一回見せてね"
    /// カメラが許可されていないのに「見て」と言われたとき
    static let cameraDeniedLine = "ごめんね、カメラが使えないんだ。問題を声で読んでくれる？"
    static let analysisFailedLine = "ごめん、写真がよく見えなかった。もう一回撮ってみようか？"

    // MARK: - 画面に出すもの

    private(set) var phase: Phase = .idle
    private(set) var conversationState: ConversationState = .idle
    /// 子どもが話したことの字幕（小さく出す）
    private(set) var caption = ""
    /// 黒板の中身（#15 の分析で出す・会話の途中で先生が出す）
    private(set) var board: BoardContent?
    /// 黒板の段階表示（どこまで見せたか）。nil なら全部見せる
    private(set) var boardReveal: BoardReveal?
    private(set) var sessionMode: SessionMode = .study
    private(set) var timer: FocusTimer?
    private(set) var statusMessage: String?
    /// Worker / Claude につながらなかった理由（保護者向けの案内を画面に出す）。つながったら消す
    private(set) var connectionProblem: ConnectionProblem?
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
    /// 最後の返事の表情（しるし、または答えの判定で決めたもの）
    private(set) var lastReplyEmotion: AvatarEmotion = .neutral
    /// 最後の子どもの発話の答えの判定（問題に取り組み中だけ）
    private(set) var lastAnswerJudgement: AnswerJudgement?
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
    @ObservationIgnored private(set) var addressingJudge: JevAddressingJudge?
    /// 返事ごとに増やす。割り込み・終了のあとで古い返事を話さないようにする
    @ObservationIgnored private var replyGeneration = 0
    /// 作っている途中・話している途中の返事の世代。なければ nil
    @ObservationIgnored private var inFlightReply: Int?
    /// いまの返事の図を黒板に出したか（出す前に割り込まれたら、履歴の tool_result を「見せていない」にする）
    @ObservationIgnored private var inFlightBoardShown = false
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
    @ObservationIgnored private(set) var tutoring: TutoringState? {
        // 答えの判定を発話の判断と一緒に先に聞けるよう、問題を揃えておく
        didSet { decisionCache?.problem = tutoring.flatMap(AnswerJudge.problemContext) }
    }
    /// 発話ごとの Jev の判断（まとめて先に聞いて覚えておく）。Jev を使わなければ nil
    @ObservationIgnored private let decisionCache: UtteranceDecisionCache?
    @ObservationIgnored private var captureJudge: (any CaptureRequestJudge)?
    /// 図を出してから話し始めた文の数（段階表示）
    @ObservationIgnored private var sentencesSinceBoard = 0
    /// 黒板をしまうかどうか（#105）
    @ObservationIgnored private var boardStage = BoardStage()
    /// 休憩のあいだ預かっている、解いている途中の問題の図（#105）
    @ObservationIgnored private var parkedBoard: (content: BoardContent, reveal: BoardReveal?)?
    @ObservationIgnored private let answerJudge: any AnswerJudging
    /// 次に話し始めるときの表情。話し始めたら neutral に戻す（定型句や声かけに持ち越さない）
    @ObservationIgnored private var pendingEmotion: AvatarEmotion = .neutral
    /// 先生のメモを最後に作ったときの出来事（励ましの指示は 1 回の返事だけに効かせる）
    @ObservationIgnored private var noteReaction: TutoringReaction?

    init(dependencies: Dependencies) {
        self.deps = dependencies
        self.tracker = SpokenReplyTracker(voice: dependencies.voice)
        self.openingBuilder = OpeningPromptBuilder(library: dependencies.library)
        let decisionCache = dependencies.decisions.map { UtteranceDecisionCache(decisions: $0) }
        self.decisionCache = decisionCache
        self.answerJudge = dependencies.answerJudge ?? AnswerJudge(cache: decisionCache)
        tracker.onSentenceStart = { [weak self] in self?.revealOnSentence() }
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
        finishConfirmationDeadline = nil
        // 前のセッションで先生が最後に話した文を、新しいセッションの発話の判断に持ち込まない
        decisionCache?.teacherLastSaid = nil
        clearBoard()
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
            // 集中と休憩の分数・声かけの言い回し（#65）。始めるときに読むので、変えたら次のセッションから効く
            settings.timer = preferences.timerSettings(base: settings.timer)
        }
        let conversation = settings.conversation
        trace("話している間のマイク: \(conversation.speakingInputMode == .bargeIn ? "開いたまま（割り込み）" : "止める")")
        var endDecider: (any EndOfUtteranceDecider)?
        if let decisionCache {
            // 言い終わったか・先生への発話か・撮影の依頼か・答えの判定は、同じ 1 回のリクエストの答えを使う
            addressingJudge = JevAddressingJudge(cache: decisionCache, fallback: CallWordAddressingJudge(callWords: conversation.callWords))
            endDecider = JevEndOfUtteranceDecider(cache: decisionCache)
            captureJudge = JevCaptureRequestJudge(cache: decisionCache)
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

        let rephraser = NudgeRephraser(client: deps.client, library: deps.library)
        let nudgeSpeaker = ConversationNudgeSpeaker(controller: controller) { [weak self] nudge in
            let varied = await rephraser.rephrase(nudge)
            self?.trace("声かけの言い回し: \(varied.map { "「\($0)」" } ?? "定型句のまま（言い換えられなかった）")")
            return varied
        }
        self.nudgeSpeaker = nudgeSpeaker
        let timer = FocusTimer(clock: deps.clock, settings: settings.timer, nudgeSink: nudgeSpeaker)
        self.timer = timer
        trace("タイマー: 集中 \(settings.timer.focusDuration.components.seconds / 60) 分・休憩 \(settings.timer.breakDuration.components.seconds / 60) 分・声かけの言い回し \(settings.timer.allowsVariation ? "変える" : "定型句")")
        timerEventsTask = Task { [weak self] in
            for await event in timer.events {
                guard let self else { return }
                await self.handleTimer(event)
            }
        }

        phase = .active
        timer.start()
        deps.watchOver?.sessionStarted(host: self)
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
            // 見守りの「ちょっと見せて？」に「うん」と答えた（#30）。同意があったときだけ撮る
            if deps.watchOver?.consumeConsent(text) == true {
                if canCapture {
                    Task { await self.runCapture() }
                    return
                }
                trace("カメラがないので撮影は省略（ふつうに返事する）")
            }
            // 「今日はここまでにする？」への返事（#103）
            if let agreed = consumeFinishConfirmation(text) {
                if agreed {
                    Task { await self.end() }
                    return
                }
            } else if await handleRequest(in: text) {
                return
            }
            let reaction = await noteTutoringTurn(text)
            // 答えだった発話は撮影の依頼ではない
            let isAnswer = lastAnswerJudgement.map { $0.verdict != .notAnAnswer } ?? false
            startReply(
                to: text, fallback: Self.replyFallback, captureCheck: isAnswer ? nil : captureCheck(for: text), cue: reaction.cue
            )
        case .utteranceIgnored(let text):
            trace("先生への発話ではないとみなした: 「\(text)」")
            if VoiceCommand.parse(text) == .end { Task { await self.end() } }
        case .bargeIn(let during):
            trace("割り込み（\(during == .speaking ? "発話中" : "考え中")）")
            await handleBargeIn()
        }
    }

    // MARK: - 休憩したい・終わりたい（#103）

    /// 先生が「今日はここまでにする？」と聞き、返事を待っている期限
    @ObservationIgnored private var finishConfirmationDeadline: ContinuousClock.Instant?
    static let finishConfirmLine = "今日はここまでにする？"
    /// 「今日はここまでにする？」の返事を待つ時間（ConversationSettings の continuationWindow と同じ）
    static let finishConfirmationWindow: Duration = .seconds(30)

    /// 休憩したい・終わりたいと言っていれば動く。返事をこれで済ませたら true（ふつうの返事を作らない）
    ///
    /// - 休憩したい：集中の途中なら、その場で休憩に切り替える（雑談モードで、ふつうに返事する）。間違えても戻せるので確かめない
    /// - 終わりたい：「今日はここまでにする？」と聞く。終えるとふり返りと保存が走るので、Jev の判断だけでは終えない
    private func handleRequest(in text: String) async -> Bool {
        let analysis = await decisionCache?.analysis(for: text, within: AnswerJudge.defaultTimeout)
        if let p = analysis?.finishRequest, DecisionReading(p) == .yes {
            trace("終わりたいと言った（Jev \(String(format: "%.2f", p))）→ 確かめる")
            finishConfirmationDeadline = deps.clock.now + Self.finishConfirmationWindow
            Task {
                await self.speakFallback([Self.finishConfirmLine])
                self.decisionCache?.teacherLastSaid = Self.finishConfirmLine
            }
            return true
        }
        let wantsBreak = analysis?.breakRequest.map { DecisionReading($0) == .yes } ?? BreakRequestDetector.isBreakRequest(text)
        if wantsBreak, sessionMode == .study, timer?.startBreakNow() == true {
            trace("休憩したいと言ったので休憩に入る（\(analysis?.breakRequest.map { "Jev \(String(format: "%.2f", $0))" } ?? "言い方")）")
            // タイマーの出来事を待たずに雑談モードにしてから返事を作る（あとから届く出来事は同じモードなので何もしない）
            await handleTimer(.phaseStarted(.rest))
        }
        return false
    }

    /// 「今日はここまでにする？」への返事なら、終えてよいか（true / false）。返事を待っていなければ nil
    private func consumeFinishConfirmation(_ text: String) -> Bool? {
        guard let deadline = finishConfirmationDeadline else { return nil }
        finishConfirmationDeadline = nil
        guard deps.clock.now <= deadline else { return nil }
        let agreed = FinishConfirmationDetector.isAgreement(text)
        trace("「\(Self.finishConfirmLine)」への返事「\(text)」→ \(agreed ? "終える" : "続ける")")
        return agreed
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
        let boardShown = inFlightBoardShown
        pendingEmotion = .neutral
        avatar.send(.userStartedSpeaking)
        guard let brain else { return true }
        let task = Task { [weak self] in
            await brain.cancel()
            await Self.truncateDroppedReply(brain, spoken: spoken, boardShown: boardShown)
            self?.trace("割り込まれたので履歴を切り詰めた（話し終えた文 \(spoken.finished.count)・途中の文 \(spoken.playedInCurrent) 文字・図 \(boardShown ? "見せた" : "見せていない")）")
        }
        truncation = task
        await task.value
        return true
    }

    /// 止めた返事の履歴を、話したところまでで切り詰める（図の前の文・続きの文をまたいで数える。#86）
    private static func truncateDroppedReply(_ brain: TeacherBrain, spoken: SpokenSnapshot, boardShown: Bool) async {
        if !boardShown { await brain.markLastReplyBoardsNotShown() }
        guard let count = ReplyTruncation.targetCount(history: await brain.history, spoken: spoken) else { return }
        await brain.truncateLastReply(toCharacterCount: count)
    }

    /// 返事を作り始める。1 文目が届くまでは考え中のまま
    ///
    /// `captureCheck` があれば（撮影の依頼かを Jev / 規則で判定中）、1 文目を話す前に答えを待ち、
    /// 撮影の依頼なら返事を捨てて撮影に移る（判定と返事の生成を並べて、待ち時間を増やさない）
    ///
    /// `cue` があれば（解けた・2回まちがえた）、その表情で話す。定型句（すごいじゃん！）は Haiku の 1 文目を待たずに話す
    private func startReply(to text: String, fallback: String, captureCheck: Task<Bool, Never>? = nil, cue: ReplyCue? = nil) {
        replyGeneration += 1
        let generation = replyGeneration
        // 割り込みが返事のタスクより先に来ても捨てられるよう、ここで印を付ける
        inFlightReply = generation
        inFlightBoardShown = false
        replyTask = Task { [weak self] in
            await self?.runReply(to: text, fallback: fallback, generation: generation, captureCheck: captureCheck, cue: cue)
        }
    }

    private func runReply(to text: String, fallback: String, generation: Int, captureCheck: Task<Bool, Never>?, cue: ReplyCue?) async {
        guard let brain, let controller else { return }
        defer { if inFlightReply == generation { inFlightReply = nil } }
        // 前の返事の切り詰めが終わってから、新しい発話を履歴に足す
        await truncation?.value
        guard generation == replyGeneration else { return }
        tracker.beginReply()
        let acceptedAt = deps.clock.now
        lastReplyLatency = nil
        let patience = settings.patience
        let stream = ReplyWatchdog.watch(
            await brain.respondWithBoards(to: text), clock: deps.clock,
            // 定型句を先に流す返事（すごいじゃん！）は、もうつないでいる
            fillerAfter: cue?.lead == nil ? patience.replyFiller : nil, giveUpAfter: patience.replyGiveUp
        )
        let (sentences, continuation) = AsyncStream<String>.makeStream()
        var speakTask: Task<SpeakOutcome, Never>?
        var spoken: [String] = []
        /// 読み上げる前の文（答え漏れで差し替える前）。履歴の位置を出すのに使う
        var originals: [String] = []
        var blockedReplacement: String?
        var wantsCapture = false
        var failure: (any Error)?
        /// 1 文目を話す前に届いた図。撮影に移るなら捨てる
        var pendingBoard: BoardContent?
        /// 返事の表情。答えの判定で決めたものを先に、なければ Haiku のしるし（[praise] など）で決める
        var emotion = cue?.emotion
        /// 先に流した定型句。Haiku の1文目が同じ言葉で始まったら、その部分は言わない（「すごいじゃん！すごいじゃん！」を防ぐ）
        var leadToSkip = cue?.lead
        if let lead = cue?.lead {
            pendingEmotion = emotion ?? .neutral
            speakTask = Task { await controller.speak(sentences) }
            spoken.append(lead)
            continuation.yield(lead)
        }
        do {
            replyLoop: for try await event in stream {
                guard generation == replyGeneration else { break }
                let output: TeacherOutput
                switch event {
                case .filler:
                    // 1 文目が遅い。撮影の依頼でなければ、定型句でつなぐ
                    guard speakTask == nil else { continue }
                    if let captureCheck, await captureCheck.value {
                        wantsCapture = true
                        break replyLoop
                    }
                    guard generation == replyGeneration else { break replyLoop }
                    trace("1文目が遅いので定型句でつなぐ")
                    pendingEmotion = .neutral
                    speakTask = Task { await controller.speak(sentences) }
                    if let board = pendingBoard {
                        presentBoard(board, pace: .sentence)
                        inFlightBoardShown = true
                        pendingBoard = nil
                    }
                    continuation.yield(Self.replyFiller)
                    continue
                case .output(let next):
                    output = next
                }
                let raw: String
                switch output {
                case .board(let content):
                    if speakTask == nil {
                        pendingBoard = content
                    } else {
                        presentBoard(content, pace: .sentence)
                        inFlightBoardShown = true
                    }
                    continue
                case .sentence(let text):
                    raw = text
                }
                if speakTask == nil, let captureCheck, await captureCheck.value {
                    wantsCapture = true
                    break
                }
                guard generation == replyGeneration else { break }
                // 気持ちのしるしは表情にして、読み上げない（EmotionTag）。しるしだけの文は話さない
                let (tag, sentence) = EmotionTag.strip(raw)
                if emotion == nil { emotion = tag }
                guard !sentence.isEmpty else {
                    originals.append(raw)
                    continue
                }
                // 答えを先に言ってしまう文は、読み上げる前に差し替える（AnswerLeakGuard）
                var line = sentence
                if let lead = leadToSkip {
                    leadToSkip = nil
                    line = Self.droppingLeadEcho(line, lead: lead)
                    if line.isEmpty {
                        originals.append(raw)
                        continue
                    }
                }
                if case .blocked(let replacement)? = tutoring?.leakGuard.check(sentence) {
                    line = replacement
                    blockedReplacement = replacement
                    trace("答えを言いそうな文を差し替えた")
                }
                if lastReplyLatency == nil {
                    let latency = deps.clock.now - acceptedAt
                    lastReplyLatency = latency
                    trace("1文目まで \(latency.formatted(.units(allowed: [.milliseconds])))")
                }
                if speakTask == nil {
                    pendingEmotion = emotion ?? .neutral
                    speakTask = Task { await controller.speak(sentences) }
                    if let board = pendingBoard {
                        presentBoard(board, pace: .sentence)
                        inFlightBoardShown = true
                        pendingBoard = nil
                    }
                }
                spoken.append(line)
                continuation.yield(line)
                if blockedReplacement != nil { break }
                originals.append(raw)
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
            await Self.truncateDroppedReply(brain, spoken: SpokenSnapshot(finished: [], playedInCurrent: 0), boardShown: false)
            trace("撮影の依頼とみなした")
            await runCapture()
            return
        }
        if let blockedReplacement {
            // 残りの文（答えの説明が続きやすい）は話さない。履歴も差し替えた文にそろえる
            await brain.cancel()
            await Self.truncateDroppedReply(
                brain, spoken: SpokenSnapshot(finished: originals, playedInCurrent: 0), boardShown: inFlightBoardShown
            )
            await brain.recordTeacherUtterance(blockedReplacement)
        }

        if let failure, generation == replyGeneration {
            // つながらない・止まった。届いたけれど話していない文字（文の途中）は履歴から消す
            let problem = ConnectionProblem(failure)
            connectionProblem = problem
            trace("Worker / Claude の失敗（\(problem)）: \(failure)")
            await brain.cancel()
            await Self.truncateDroppedReply(
                brain, spoken: SpokenSnapshot(finished: originals, playedInCurrent: 0), boardShown: inFlightBoardShown
            )
        }

        if speakTask == nil {
            // 1 文も話さなかった
            guard generation == replyGeneration, phase == .active else { return }
            if let board = pendingBoard { presentBoard(board, pace: .sentence) }
            lastReplyFromWorker = false
            trace("返事を作れなかった: \(failure.map { String(describing: $0) } ?? "空の返事")")
            // つながらないときは端末の声で「調子が悪い」と伝えてから聞き直す（固まらない）
            await speakFallback(failure == nil ? [fallback] : [Self.troubleLine, fallback])
            completedReplies += 1
            return
        }
        if failure == nil { connectionProblem = nil }
        lastReplyFromWorker = failure == nil
        lastReplySentences = spoken
        lastReplyEmotion = emotion ?? .neutral
        decisionCache?.teacherLastSaid = spoken.last
        let outcome = await speakTask?.value
        trace("返事（表情 \(lastReplyEmotion.rawValue)）: \(spoken.joined()) → \(outcome.map { "\($0)" } ?? "-")")
        if failure != nil, outcome == .completed, generation == replyGeneration, phase == .active {
            // 返事が途中で止まった。話せたところまで話してから聞き直す
            await speakFallback([Self.troubleLine, Self.replyFallback])
        }
        if failure == nil, outcome == .completed, generation == replyGeneration, phase == .active,
           boardStage.replyFinished(showedBoard: inFlightBoardShown, pace: board == nil ? nil : boardReveal?.pace) {
            putAwayBoard(reason: "図を使わない返事が\(BoardStage.quietRepliesBeforePutAway)回続いた")
        }
        completedReplies += 1
    }

    /// 決まり文句を 1 回の発話として話し、履歴にも残す
    private func speakFallback(_ lines: [String]) async {
        guard let brain, let controller else { return }
        for line in lines { await brain.recordTeacherUtterance(line) }
        let (stream, continuation) = AsyncStream<String>.makeStream()
        for line in lines { continuation.yield(line) }
        continuation.finish()
        await controller.speak(stream)
    }

    // MARK: - 撮影と問題の分析（#15）

    /// 「これ見て」などの撮影の依頼かを判定し始める。カメラがなければ判定しない
    private func captureCheck(for text: String) -> Task<Bool, Never>? {
        guard let judge = captureJudge, canCapture, !isCapturing else { return nil }
        // 問題を見たあとの「わかんない」はヒントを求める発話。「見て」と言われたときだけ撮り直す
        if tutoring != nil, lastAnswerJudgement?.asksForHelp ?? HelpRequestDetector.isHelpRequest(text),
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
            let conversation = EmotionTag.strip(await brain.history.messages)
            // 返事が来ないまま撮影中で固まらないよう、一定時間で諦める（#66）
            let result = try await Deadline.run(settings.patience.analysisGiveUp, clock: deps.clock) {
                try await analyzer.analyze(jpegData: jpeg, conversation: conversation)
            }
            _ = await filler.value
            await applyAnalysis(result)
            avatar.send(.lookAwayFromNotebook)
            guard phase == .active else { return }
            startReply(to: Self.photoShownTrigger, fallback: Self.replyFallback)
        } catch {
            avatar.send(.lookAwayFromNotebook)
            trace("撮影か分析に失敗: \(error)")
            let lines: [String]
            switch error {
            case CameraError.unauthorized: lines = [Self.cameraDeniedLine]
            case is CameraError: lines = [Self.captureFailedLine]
            case is ProblemAnalyzerError: lines = [Self.analysisFailedLine]
            default:
                // 写真が悪いのではなく、つながらない
                connectionProblem = ConnectionProblem(error)
                lines = [Self.troubleLine, Self.analysisOfflineLine]
            }
            await speakFallback(lines)
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
        trace("分析した: \(analysis.kind.rawValue)「\(analysis.problemSummary)」黒板 \(result.boards.count) 枚")
        presentBoard(result.boards.first ?? .text(analysis.problemSummary), pace: .hintStage)
        await updateTeacherNote()
    }

    /// 子どもの発話を答えとして判定し、ヒントの段階を進める（解けた・違う答え・助けを求めた）（#73）
    private func noteTutoringTurn(_ text: String) async -> TutoringReaction {
        lastAnswerJudgement = nil
        guard let current = tutoring else { return .none }
        let startedAt = deps.clock.now
        let judgement = await answerJudge.judge(text, tutoring: current)
        // 判定を待つ間に撮り直した・終わったなら使わない
        guard var state = tutoring, state.analysis == current.analysis else { return .none }
        lastAnswerJudgement = judgement
        let levelBefore = state.ladder.level
        let reaction = state.react(to: text, verdict: judgement.verdict, asksForHelp: judgement.asksForHelp)
        tutoring = state
        if reaction != .none {
            revealOnHintStage(advancedBy: state.ladder.level - levelBefore, solved: state.ladder.isSolved)
        }
        let elapsed = (deps.clock.now - startedAt).formatted(.units(allowed: [.milliseconds]))
        trace("答えの判定: \(judgement.verdict.rawValue)（\(judgement.source.rawValue)・\(elapsed)）→ \(reaction)")
        // 励ましの指示は 1 回の返事だけに効かせる（次の発話で消す）
        let clearsEncouragement = noteReaction == .wrongAttempt(advanced: true)
        guard reaction != .none || clearsEncouragement else { return reaction }
        if reaction != .none {
            trace("ヒントの段階: \(state.ladder.level)/\(state.ladder.stages.count)\(state.ladder.isSolved ? "（自分で解けた）" : "")")
        }
        await updateTeacherNote(reaction: reaction)
        return reaction
    }

    private func updateTeacherNote(reaction: TutoringReaction? = nil) async {
        guard let state = tutoring else { return }
        noteReaction = reaction
        if var last = problems.last {
            last.hintLevelReached = state.ladder.level
            last.solvedBySelf = state.ladder.isSolved
            problems[problems.count - 1] = last
        }
        teacherNote = TeacherNote.make(analysis: state.analysis, ladder: state.ladder, reaction: reaction)
        await rebuildSystemPrompt()
    }

    private func handleTimer(_ event: FocusTimerEvent) async {
        guard case .phaseStarted(let next) = event else { return }
        let mode: SessionMode = next == .rest ? .rest : .study
        guard mode != sessionMode else { return }
        sessionMode = mode
        avatar.send(mode == .rest ? .breakStarted : .breakEnded)
        if mode == .rest {
            if BoardStage.keepsThroughBreak(boardReveal?.pace), let board {
                parkedBoard = (board, boardReveal)
            }
            putAwayBoard(reason: "休憩に入った")
        } else if let parked = parkedBoard {
            // 解いていた問題の図を出し直す（見せていたところまで）
            parkedBoard = nil
            board = parked.content
            boardReveal = parked.reveal
            boardStage.boardPresented()
            trace("休憩が終わったので、解いていた問題の図を出し直した")
        }
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
        deps.watchOver?.sessionEnded()
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
            transcript: EmotionTag.strip(await brain.history.messages),
            problems: problems,
            flags: await brain.sessionFlags
        )
        var reflector = SessionReflector(client: deps.client, library: deps.library)
        reflector.reflectionTimeout = settings.patience.reflectionGiveUp
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
        await controller.speak(EmotionTag.strip(closing).text)

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
        clearBoard()
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
        var emotion = AvatarEmotion.neutral
        if next == .speaking {
            emotion = pendingEmotion
            pendingEmotion = .neutral
            if emotion != .neutral { trace("先生の表情: \(emotion.rawValue)") }
        }
        for event in Self.avatarEvents(from: previous, to: next, emotion: emotion) { avatar.send(event) }
        // 返事を待っている間（最初のひと言の前など、まだ待機のとき）に話し始めた。割り込みの出来事は出ないので、ここで捨てる
        if next == .listening, inFlightReply == replyGeneration {
            Task { await self.dropInFlightReply() }
        }
    }

    /// 会話の状態の変わり方から、アバターに送るできごと
    static func avatarEvents(
        from previous: ConversationState, to next: ConversationState, emotion: AvatarEmotion = .neutral
    ) -> [AvatarEvent] {
        switch next {
        case .listening: [.userStartedSpeaking]
        case .thinking: [.thinkingStarted]
        case .speaking: [.speakingStarted(emotion: emotion)]
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
        if preview == .idle {
            phase = .idle
            return
        }
        phase = .active
        let timer = FocusTimer(clock: deps.clock, settings: settings.timer)
        timer.start()
        self.timer = timer
        switch preview {
        case .praise: pendingEmotion = .praise
        case .encourage: pendingEmotion = .encourage
        default: break
        }
        conversationStateChanged(to: [.listening, .teacher].contains(preview) ? .listening : .speaking)
        switch preview {
        case .listening, .teacher:
            caption = "ねえ先生、この割合の問題がよくわかんない"
        case .praise:
            caption = "わかった！24平方センチだ！"
            board = BoardSamples.content(.stepCards)
        case .encourage:
            caption = "じゃあ10平方センチかな？"
            board = BoardSamples.content(.stepCards)
        case .board:
            caption = ""
            presentBoard(SessionPreviewState.previewBoard(), pace: .sentence)
            boardReveal?.revealAll()
        case .tour:
            caption = ""
        case .idle, .speaking:
            caption = ""
            board = BoardSamples.content(.stepCards)
            boardReveal = BoardReveal(content: BoardSamples.content(.stepCards), pace: .sentence, initiallyShown: 2)
        }
    }

    /// 黒板の出し入れを順にくり返す（`-sessionPreview tour`。動画で切り替えを確かめる。#105）
    func runBoardTour() async {
        func wait(_ seconds: Double) async -> Bool {
            try? await Task.sleep(for: .seconds(seconds))
            return !Task.isCancelled
        }
        while !Task.isCancelled {
            // 先生だけで聞いている
            putAwayBoard(reason: "表示確認")
            conversationStateChanged(to: .listening)
            caption = "ねえ先生、割合の問題がわかんない"
            guard await wait(3) else { return }
            // 書きながら話す：黒板が広がって、先生は右下へ
            caption = ""
            conversationStateChanged(to: .speaking)
            presentBoard(BoardSamples.content(.stepCards), pace: .sentence)
            for _ in 0..<3 {
                guard await wait(1.6) else { return }
                boardReveal?.advance()
            }
            guard await wait(2) else { return }
            // 図の差し替え：黒板消しで消して書き直す
            for name in ["segment_diagram", "percent_bar", "table", "svg"] {
                presentBoard(SessionPreviewState.board(named: name), pace: .sentence)
                guard await wait(3.2) else { return }
            }
            // 自由に描く黒板：step ごとに 1 本ずつ書き足す（#107）
            for name in ["chalk_drawing", "drawing_circuit"] {
                presentBoard(SessionPreviewState.board(named: name), pace: .sentence)
                while boardReveal?.isComplete == false {
                    guard await wait(1.8) else { return }
                    boardReveal?.advance()
                }
                guard await wait(2.2) else { return }
            }
            // 子どもが話す（黒板は出したまま）
            conversationStateChanged(to: .listening)
            caption = "あ、わかったかも！"
            guard await wait(2.5) else { return }
            caption = ""
            conversationStateChanged(to: .speaking)
            guard await wait(2) else { return }
        }
    }

    // MARK: - 黒板（#70）

    /// 黒板に図を出す。答えが書かれていたらそこだけ「？」にし、段階表示を始める
    func presentBoard(_ content: BoardContent, pace: BoardReveal.Pace) {
        var shown = content
        if let leakGuard = tutoring?.leakGuard {
            let masked = leakGuard.mask(content)
            shown = masked.content
            if masked.maskedCount > 0 { trace("黒板の答えを「？」にした（\(masked.maskedCount) か所）") }
        }
        board = shown
        boardReveal = BoardReveal(content: shown, pace: pace)
        boardStage.boardPresented()
        parkedBoard = nil
        // 1 つ目は、いま話している文（まだなら次に話し始める文）に合わせる
        sentencesSinceBoard = tracker.isSpeaking ? 1 : 0
        trace("黒板: \(Self.describe(shown))（\(boardReveal.map { "\($0.shown)/\($0.total)" } ?? "-")）")
    }

    /// 黒板をしまって先生だけにする（#105）
    private func putAwayBoard(reason: String) {
        guard board != nil else { return }
        board = nil
        boardReveal = nil
        boardStage.reset()
        trace("黒板をしまった（\(reason)）")
    }

    private func clearBoard() {
        board = nil
        boardReveal = nil
        boardStage.reset()
        parkedBoard = nil
    }

    /// 話している文に合わせる図は、文を話し始めるたびに 1 つ増やす（最初の 1 つは図を出したときに見せている）
    private func revealOnSentence() {
        guard var reveal = boardReveal, reveal.pace == .sentence, !reveal.isComplete else { return }
        sentencesSinceBoard += 1
        guard sentencesSinceBoard > 1 else { return }
        reveal.advance()
        boardReveal = reveal
    }

    /// ヒントの段階に合わせる図は、段階が進んだぶん増やす。自分で解けたら全部見せる
    private func revealOnHintStage(advancedBy steps: Int, solved: Bool) {
        guard var reveal = boardReveal, reveal.pace == .hintStage else { return }
        if solved { reveal.revealAll() } else { reveal.advance(by: steps) }
        boardReveal = reveal
    }

    /// 記録用の短い説明（部品の種類）
    static func describe(_ content: BoardContent) -> String {
        switch content {
        case .component(let title, let component): "\(component.kind.rawValue)「\(title)」"
        case .svg: "svg"
        case .text: "文字"
        }
    }

    /// 分析の結果を、撮影せずに入れる（`-autoSession` の自己テストで、決まった問題に答える台本を流すため）
    func beginProblem(_ result: AnalysisResult) async {
        guard phase == .active else { return }
        await applyAnalysis(result)
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

    // MARK: - 音声の中断（#75。AudioSessionMonitor が呼ぶ）

    /// 中断から戻ったときのひと言
    static let welcomeBackLine = "おかえり！続きやろっか"

    /// 電話・Siri などで音声が中断された。作りかけの返事と聞きかけの発話を捨て、タイマーを止める
    func pauseForAudioInterruption() async {
        guard phase == .active else { return }
        trace("音声が中断された（タイマーを止める）")
        timer?.pause()
        // 先に会話を待機に戻す（声を止めたあとで、残りの文に進まないように）
        controller?.stop()
        if await dropInFlightReply() == false { deps.voice.stop() }
    }

    /// 中断から戻った（マイクと先生の声は作り直してある）。タイマーを動かし、声をかける
    func resumeAfterAudioInterruption() async {
        guard phase == .active else { return }
        trace("音声の中断から戻った")
        timer?.resume()
        await controller?.speak(Self.welcomeBackLine)
    }
}

/// いま一緒に取り組んでいる問題
struct TutoringState: Sendable {
    var analysis: ProblemAnalysis
    var ladder: HintLadder
    var leakGuard: AnswerLeakGuard
}
