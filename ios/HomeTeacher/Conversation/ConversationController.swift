import Foundation
import Observation

/// 学習セッション中の会話のターンを管理する状態機械。
///
/// - 呼びかけ語で始まる発話（または `AddressingJudge` が先生への発話と判断したもの）と、
///   先生の発話が終わってから `continuationWindow` 以内に話し始めた発話に応答する
/// - 声が止まってから `endOfUtteranceSilence` 無音が続いたら言い終わったとみなす。
///   `EndOfUtteranceDecider` が「言い終わった」と返せば、それより早く区切る
/// - 先生の考え中・発話中に子どもが話し始めたら `.bargeIn` を出して聞き取りに移る
///   （`muteWhileSpeaking` モードでは発話中の入力を捨てる）
///
/// 音声の入出力と時計はプロトコルで受け取るので、ここには AVFoundation は出てこない。
@MainActor
@Observable
final class ConversationController {
    private(set) var state: ConversationState = .idle

    let settings: ConversationSettings
    /// 出来事の通知。AsyncStream なので購読者は 1 つだけ
    let events: AsyncStream<ConversationEvent>

    @ObservationIgnored private let eventContinuation: AsyncStream<ConversationEvent>.Continuation
    @ObservationIgnored private let input: any SpeechInput
    @ObservationIgnored private let output: any SpeechOutput
    @ObservationIgnored private let clock: any ConversationClock
    @ObservationIgnored private let addressingJudge: any AddressingJudge
    @ObservationIgnored private let endOfUtteranceDecider: (any EndOfUtteranceDecider)?

    @ObservationIgnored private var inputTask: Task<Void, Never>?
    @ObservationIgnored private var utterance: Utterance?
    @ObservationIgnored private var nextUtteranceID = 0
    @ObservationIgnored private var silenceTimer: (any ScheduledAction)?
    /// 先生の発話が終わった（または割り込まれた）時刻。30 秒ルールの起点
    @ObservationIgnored private var teacherSpeechEndedAt: ContinuousClock.Instant?
    /// 発話ごとに増やす。割り込みや停止のあとで古い speak が状態を戻さないようにする
    @ObservationIgnored private var speechID = 0

    /// 聞き取り中の発話
    private struct Utterance {
        let id: Int
        /// 話し始めた時点で 30 秒ルールの範囲内だったか
        let isContinuation: Bool
        var transcript = ""
        var isVoiceActive = true
        /// 言い終わったと判断し、呼びかけかどうかを判定している最中
        var isFinalizing = false
    }

    init(
        input: any SpeechInput,
        output: any SpeechOutput,
        clock: any ConversationClock,
        settings: ConversationSettings = ConversationSettings(),
        addressingJudge: (any AddressingJudge)? = nil,
        endOfUtteranceDecider: (any EndOfUtteranceDecider)? = nil
    ) {
        self.input = input
        self.output = output
        self.clock = clock
        self.settings = settings
        self.addressingJudge = addressingJudge ?? CallWordAddressingJudge(callWords: settings.callWords)
        self.endOfUtteranceDecider = endOfUtteranceDecider
        (events, eventContinuation) = AsyncStream.makeStream(of: ConversationEvent.self)
    }

    // MARK: - セッション

    /// 入力の購読を始める（学習セッションの開始）
    func start() {
        guard inputTask == nil else { return }
        let stream = input.events
        inputTask = Task { [weak self] in
            for await event in stream {
                self?.handle(event)
            }
        }
    }

    /// 入力の購読をやめて待機に戻る（学習セッションの終了）
    func stop() {
        inputTask?.cancel()
        inputTask = nil
        resetUtterance()
        speechID += 1
        transition(to: .idle)
    }

    // MARK: - 入力

    /// 音声入力の出来事を 1 つ処理する。通常は `start()` が呼ぶ
    func handle(_ event: SpeechInputEvent) {
        if state == .speaking && settings.speakingInputMode == .muteWhileSpeaking {
            // マイクを止めている間に届いたもの（止まりきる前の残りなど）は捨てる
            return
        }
        switch (state, event) {
        case (.idle, .voiceStarted):
            beginUtterance(isContinuation: isWithinContinuationWindow)

        case (.thinking, .voiceStarted), (.speaking, .voiceStarted):
            let interrupted = state
            if interrupted == .speaking { teacherSpeechEndedAt = clock.now }
            speechID += 1
            // 先生と話している最中なので、この発話は会話の続きとして扱う
            beginUtterance(isContinuation: true)
            eventContinuation.yield(.bargeIn(during: interrupted))

        case (.listening, .voiceStarted):
            if utterance?.isFinalizing ?? true {
                // 判定中に話し始めたら、新しい発話として聞き直す
                beginUtterance(isContinuation: (utterance?.isContinuation ?? false) || isWithinContinuationWindow)
            } else {
                // 言い終わる前の息継ぎ。無音のタイマーを止めて聞き続ける
                cancelSilenceTimer()
                utterance?.isVoiceActive = true
            }

        case (.listening, .voiceEnded):
            guard let current = utterance, !current.isFinalizing else { return }
            utterance?.isVoiceActive = false
            startSilenceTimer(for: current.id)
            askEndOfUtterance()

        case (.listening, .transcript(let text)):
            guard let current = utterance, !current.isFinalizing else { return }
            utterance?.transcript = text
            // 書き起こしは声より遅れて届くので、無音中に更新されたら改めて聞く
            if !current.isVoiceActive { askEndOfUtterance() }

        default:
            break
        }
    }

    // MARK: - 出力

    /// 先生が話す。文ごとに `SpeechOutput` へ流す。
    /// 待機中（自分から声をかける）か考え中のときだけ話せる。
    @discardableResult
    func speak(_ sentences: AsyncStream<String>) async -> SpeakOutcome {
        guard state == .idle || state == .thinking else { return .rejected }
        resetUtterance()
        speechID += 1
        let id = speechID
        transition(to: .speaking)

        for await sentence in sentences {
            guard isCurrentSpeech(id) else { break }
            await output.speak(sentence)
        }
        guard isCurrentSpeech(id) else { return .interrupted }
        teacherSpeechEndedAt = clock.now
        transition(to: .idle)
        return .completed
    }

    @discardableResult
    func speak(_ text: String) async -> SpeakOutcome {
        await speak(AsyncStream { continuation in
            continuation.yield(text)
            continuation.finish()
        })
    }

    /// 考え中の応答を取りやめて待機に戻る（応答の生成に失敗したときなど）
    func cancelResponse() {
        guard state == .thinking else { return }
        transition(to: .idle)
    }

    // MARK: - 内部

    private var isWithinContinuationWindow: Bool {
        guard let endedAt = teacherSpeechEndedAt else { return false }
        return clock.now - endedAt <= settings.continuationWindow
    }

    private func isCurrentSpeech(_ id: Int) -> Bool {
        state == .speaking && speechID == id
    }

    private func beginUtterance(isContinuation: Bool) {
        cancelSilenceTimer()
        nextUtteranceID += 1
        utterance = Utterance(id: nextUtteranceID, isContinuation: isContinuation)
        transition(to: .listening)
    }

    private func resetUtterance() {
        cancelSilenceTimer()
        utterance = nil
    }

    private func startSilenceTimer(for id: Int) {
        cancelSilenceTimer()
        silenceTimer = clock.schedule(after: settings.endOfUtteranceSilence) { [weak self] in
            self?.finalizeUtterance(id)
        }
    }

    private func cancelSilenceTimer() {
        silenceTimer?.cancel()
        silenceTimer = nil
    }

    /// 無音のタイムアウトを待たずに「言い終わったか」を聞く
    private func askEndOfUtterance() {
        guard let decider = endOfUtteranceDecider,
              let current = utterance, !current.transcript.isEmpty else { return }
        let id = current.id
        let transcript = current.transcript
        Task { [weak self] in
            let isComplete = await decider.isUtteranceComplete(transcript)
            // 返事を待つ間に話し始めた・書き起こしが変わった場合は使わない
            guard isComplete, let self, let latest = self.utterance, latest.id == id,
                  !latest.isVoiceActive, latest.transcript == transcript else { return }
            self.finalizeUtterance(id)
        }
    }

    /// 言い終わった発話に応答するかを決める
    private func finalizeUtterance(_ id: Int) {
        guard state == .listening, let current = utterance, current.id == id, !current.isFinalizing else { return }
        cancelSilenceTimer()
        utterance?.isFinalizing = true

        let text = current.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            // 物音だけで言葉がなかった
            utterance = nil
            transition(to: .idle)
            return
        }
        if current.isContinuation {
            accept(text)
            return
        }
        let judge = addressingJudge
        Task { [weak self] in
            let addressed = await judge.isAddressedToTeacher(text)
            guard let self, self.state == .listening, self.utterance?.id == id else { return }
            if addressed {
                self.accept(text)
            } else {
                self.utterance = nil
                self.transition(to: .idle)
                self.eventContinuation.yield(.utteranceIgnored(text))
            }
        }
    }

    private func accept(_ text: String) {
        utterance = nil
        transition(to: .thinking)
        eventContinuation.yield(.userTurnAccepted(text))
    }

    private func transition(to next: ConversationState) {
        let wasSpeaking = state == .speaking
        state = next
        guard settings.speakingInputMode == .muteWhileSpeaking else { return }
        if !wasSpeaking && next == .speaking { input.setMuted(true) }
        if wasSpeaking && next != .speaking { input.setMuted(false) }
    }
}
