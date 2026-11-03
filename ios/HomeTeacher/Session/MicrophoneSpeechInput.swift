@preconcurrency import AVFoundation
import OSLog

/// 本番の音声入力。#9 のスパイクの `AudioPipeline`（voice processing を有効にした AVAudioEngine）でマイクを開き、
/// 認識エンジン（SpeechTranscriber → DictationTranscriber → SFSpeechRecognizer の順）に流す。
///
/// - 話し始め・話し終わりは `SpeechEventShaper`（音量のヒステリシス + 文字の届き方）で決める
/// - 先生の声は同じエンジン（`engine`）に `EngineClipPlayer` をつないで流す（#13 の実機検証で混入 0%）。
///   エンジンを止めると先生の声も止まるので、ミュートはエンジンを止めずに「認識に渡さない」だけにする
/// - 学習セッション画面を開いている間ずっと動かす（待機中の「勉強スタート」も聞くため）
@MainActor
final class MicrophoneSpeechInput: SpeechInput {
    enum StartError: LocalizedError {
        case microphoneDenied
        case noRecognizer

        var errorDescription: String? {
            switch self {
            case .microphoneDenied: "マイクが許可されていません（設定 > プライバシー > マイク）"
            case .noRecognizer: "日本語の音声認識を始められませんでした"
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

        let support = await SpeechSupportProbe.probe()
        let kinds = Self.candidateKinds(support)
        logger.info("認識エンジンの候補: \(kinds.map(\.rawValue).joined(separator: ", "), privacy: .public)")

        let feed = feed
        try pipeline.start(
            voiceProcessing: true,
            onBuffer: { feed.append($0) },
            onLevel: { [weak self] level in
                Task { @MainActor in self?.receiveLevel(level) }
            }
        )

        for kind in kinds {
            let recognizer: any LiveRecognizer = kind == .sfSpeechRecognizer ? SFRecognizer() : AnalyzerRecognizer(kind: kind)
            feed.set(recognizer)
            do {
                try await recognizer.start(inputFormat: pipeline.inputFormat) { [weak self] text, isFinal in
                    Task { @MainActor in self?.receiveText(text, isFinal: isFinal) }
                }
                self.recognizer = recognizer
                recognizerKind = kind
                shaper.useCumulativeTranscripts(kind == .sfSpeechRecognizer)
                isRunning = true
                logger.info("聞き取りを開始: \(kind.rawValue, privacy: .public)")
                return kind
            } catch {
                feed.set(nil)
                logger.error("\(kind.rawValue, privacy: .public) を始められなかった: \(String(describing: error), privacy: .public)")
            }
        }
        pipeline.stop()
        throw StartError.noRecognizer
    }

    func stop() async {
        guard isRunning else { return }
        isRunning = false
        pipeline.stop()
        feed.set(nil)
        await recognizer?.stop()
        recognizer = nil
        recognizerKind = nil
    }

    func setMuted(_ muted: Bool) {
        feed.setMuted(muted)
        shaper.setMuted(muted)
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

    private func receiveLevel(_ level: Float) {
        guard isRunning else { return }
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

    private func receiveText(_ text: String, isFinal: Bool) {
        guard isRunning else { return }
        emit(shaper.text(text, isFinal: isFinal, at: .now))
    }

    private func emit(_ events: [SpeechInputEvent]) {
        for event in events { continuation.yield(event) }
    }
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
