@preconcurrency import AVFoundation
import OSLog

/// 本番の音声入力。#9 のスパイクの `AudioPipeline`（voice processing を有効にした AVAudioEngine）でマイクを開き、
/// 認識エンジン（SpeechTranscriber → DictationTranscriber → SFSpeechRecognizer の順）に流す。
///
/// - 話し始め・話し終わりは `SpeechEventShaper`（音量のヒステリシス + 文字の届き方）で決める
/// - 先生の声は同じエンジン（`engine`）に `EngineClipPlayer` をつないで流す（#13 の実機検証で混入 0%）。
///   エンジンを止めると先生の声も止まるので、ミュートはエンジンを止めずに「認識に渡さない」だけにする
/// - 学習セッション画面を開いている間ずっと動かす（待機中の「勉強スタート」も聞くため）
/// - 中断（電話・Siri）や機器の切り替えでは `suspend()` で止め、`resume()` で作り直す（#75。`AudioSessionMonitor` が呼ぶ）
@MainActor
final class MicrophoneSpeechInput: SpeechInput {
    enum StartError: LocalizedError {
        case microphoneDenied
        case noRecognizer
        /// 始めている間に止められた（中断・作り直しのタイムアウト）
        case superseded

        var errorDescription: String? {
            switch self {
            case .microphoneDenied: "マイクが許可されていません（設定 > プライバシー > マイク）"
            case .noRecognizer: "日本語の音声認識を始められませんでした"
            case .superseded: "聞き取りを始めている間に止められました"
            }
        }
    }

    let events: AsyncStream<SpeechInputEvent>
    private let continuation: AsyncStream<SpeechInputEvent>.Continuation
    let pipeline: AudioPipeline
    private(set) var recognizerKind: RecognizerKind?
    private(set) var isRunning = false
    private var shaper = SpeechEventShaper()
    private var recognizer: (any LiveRecognizer)?
    private let feed = RecognizerFeed()
    /// 止めるたびに増やす。止める前の認識エンジン・タップから遅れて届いた結果を捨てる
    private var generation = 0
    private var mute = MicrophoneMuteState()
    /// 最初に調べた認識エンジンの候補（作り直すときは調べ直さない）
    private var kinds: [RecognizerKind]?
    private let logger = Logger(subsystem: "com.kawamataryo.HomeTeacher", category: "SpeechInput")
    /// 音量のしきい値を実機で合わせるための記録（2 秒ごとに最大値を出す）
    private var levelPeak: Float = 0
    private var levelPeakSince = ContinuousClock.now

    /// 音量を受け取るたびに呼ぶ（画面の表示用）
    var onLevel: ((Float) -> Void)?

    init(pipeline: AudioPipeline = AudioPipeline(), detector: VoiceActivityDetector = VoiceActivityDetector()) {
        self.pipeline = pipeline
        shaper = SpeechEventShaper(detector: detector)
        (events, continuation) = AsyncStream.makeStream(of: SpeechInputEvent.self)
    }

    /// AVAudioEngine。先生の声（`EngineClipPlayer`）は `start()` が成功したあとにこれへつなぐ
    var engine: AVAudioEngine { pipeline.engine }

    /// マイクを開いて聞き取りを始める。使えた認識エンジンを返す
    @discardableResult
    func start() async throws -> RecognizerKind {
        if isRunning, let recognizerKind { return recognizerKind }
        guard await AVAudioApplication.requestRecordPermission() else { throw StartError.microphoneDenied }
        try pipeline.configureSession()

        let kinds: [RecognizerKind]
        if let cached = self.kinds {
            kinds = cached
        } else {
            kinds = Self.candidateKinds(await SpeechSupportProbe.probe())
            self.kinds = kinds
            logger.info("認識エンジンの候補: \(kinds.map(\.rawValue).joined(separator: ", "), privacy: .public)")
        }

        generation += 1
        let current = generation
        let feed = feed
        try pipeline.start(
            voiceProcessing: true,
            onBuffer: { feed.append($0) },
            onLevel: { [weak self] level in
                Task { @MainActor in self?.receiveLevel(level, generation: current) }
            }
        )

        for kind in kinds {
            // 認識エンジンの開始を待っている間に止められた（作り直しがタイムアウトして、次の試みが始まった）。
            // パイプラインと feed はもう次の試みのものなので触らない
            guard current == generation else { throw StartError.superseded }
            let recognizer: any LiveRecognizer = kind == .sfSpeechRecognizer ? SFRecognizer() : AnalyzerRecognizer(kind: kind)
            feed.set(recognizer)
            do {
                try await recognizer.start(inputFormat: pipeline.inputFormat) { [weak self] text, isFinal in
                    Task { @MainActor in self?.receiveText(text, isFinal: isFinal, generation: current) }
                }
                guard current == generation else {
                    await recognizer.stop()
                    throw StartError.superseded
                }
                self.recognizer = recognizer
                recognizerKind = kind
                shaper.useCumulativeTranscripts(kind == .sfSpeechRecognizer)
                isRunning = true
                logger.info("聞き取りを開始: \(kind.rawValue, privacy: .public)")
                return kind
            } catch StartError.superseded {
                throw StartError.superseded
            } catch {
                guard current == generation else { throw StartError.superseded }
                feed.set(nil)
                logger.error("\(kind.rawValue, privacy: .public) を始められなかった: \(String(describing: error), privacy: .public)")
            }
        }
        pipeline.stop()
        throw StartError.noRecognizer
    }

    func stop() async {
        guard isRunning else { return }
        generation += 1
        isRunning = false
        pipeline.stop()
        feed.set(nil)
        await recognizer?.stop()
        recognizer = nil
        recognizerKind = nil
    }

    /// 中断（電話・Siri・他のアプリ）や機器の切り替えで、エンジンと認識をいったん止める。
    ///
    /// 話している途中だったら「話し終わった」を出す（タップが止まると話し終わりが来ず、会話が「聞いてる」のまま止まるため）。
    /// 止める前の認識エンジンは後ろで止める（止まりきらない端末があるので待たない。遅れて届いた結果は `generation` で捨てる）
    func suspend() {
        generation += 1
        let wasSpeaking = shaper.isVoiceActive
        mute.suspended = true
        applyMute()
        if wasSpeaking { continuation.yield(.voiceEnded) }
        guard isRunning else { return }
        isRunning = false
        pipeline.stop()
        feed.set(nil)
        if let old = recognizer { Task { await old.stop() } }
        recognizer = nil
        recognizerKind = nil
        logger.info("聞き取りを中断")
    }

    /// `suspend()` のあと、エンジン（タップ・voice processing）と認識を作り直して聞き取りを再開する。
    /// ミュートは止める前の状態（先生が話しているか）に戻す
    @discardableResult
    func resume() async throws -> RecognizerKind {
        let kind = try await start()
        mute.suspended = false
        applyMute()
        logger.info("聞き取りを再開: \(kind.rawValue, privacy: .public)")
        return kind
    }

    func setMuted(_ muted: Bool) {
        mute.requested = muted
        applyMute()
    }

    private func applyMute() {
        feed.setMuted(mute.isMuted)
        shaper.setMuted(mute.isMuted)
    }

    /// 「勉強スタート」などのコマンドを聞き取った直後に、その文字を次の発話に持ち越さない
    func discardCurrentUtterance() {
        shaper.discardCurrentUtterance()
    }

    /// SpeechTranscriber（iOS 26）→ DictationTranscriber → SFSpeechRecognizer の順で、日本語に対応しているもの
    nonisolated static func candidateKinds(_ support: LocaleSupport) -> [RecognizerKind] {
        var kinds: [RecognizerKind] = []
        if support.speechTranscriberAvailable && support.speechTranscriberSupportsJa { kinds.append(.speechTranscriber) }
        if support.dictationSupportsJa { kinds.append(.dictationTranscriber) }
        if support.sfSupportsJa { kinds.append(.sfSpeechRecognizer) }
        return kinds
    }

    private func receiveLevel(_ level: Float, generation: Int) {
        guard isRunning, generation == self.generation else { return }
        onLevel?(level)
        let now = ContinuousClock.now
        levelPeak = max(levelPeak, level)
        if now - levelPeakSince >= .seconds(2) {
            logger.debug("音量の最大値（2秒）: \(self.levelPeak, privacy: .public)")
            levelPeak = 0
            levelPeakSince = now
        }
        emit(shaper.level(level, at: now))
    }

    private func receiveText(_ text: String, isFinal: Bool, generation: Int) {
        guard isRunning, generation == self.generation else { return }
        emit(shaper.text(text, isFinal: isFinal, at: .now))
    }

    private func emit(_ events: [SpeechInputEvent]) {
        for event in events { continuation.yield(event) }
    }
}

/// ミュートの理由。先生が話している間（ConversationController が頼む）と、中断・作り直しの間（`suspend()`）を分けて持つ。
/// どちらか一方でもあればミュート（中断中に `setMuted(false)` が来ても、中断が明けるまでは聞かない）
struct MicrophoneMuteState: Equatable, Sendable {
    var requested = false
    var suspended = false

    var isMuted: Bool { requested || suspended }
}

/// 音声のスレッドから認識エンジンにバッファを渡す。ミュート中は渡さない
private final class RecognizerFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var recognizer: (any LiveRecognizer)?
    private var muted = false

    func set(_ recognizer: (any LiveRecognizer)?) {
        lock.withLock { self.recognizer = recognizer }
    }

    func setMuted(_ muted: Bool) {
        lock.withLock { self.muted = muted }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let target = lock.withLock { muted ? nil : recognizer }
        target?.append(buffer)
    }
}
