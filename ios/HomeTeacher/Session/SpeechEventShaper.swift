import Foundation

/// マイクの音量と認識結果から、`SpeechInputEvent`（話し始め・話し終わり・書き起こし）を作る。
///
/// - 話しているかは `VoiceActivityDetector`（音量のヒステリシス + 文字の届き方）で決める
/// - 話し終わってから `utteranceGap` 以上あいて話し始めたら、新しい発話として文字を数え直す。
///   それより短い間（息継ぎ）は同じ発話の続き（ConversationController は無音 700ms で区切るので、それより長くする）
/// - 途中の文字を置きかえるだけの確定結果は、話したことにしない（区切ったあとに遅れて届く確定で、同じ発話が 2 回受け付けられないように）
/// - ミュート中（先生が話している間はマイクを止めるモード）は何も出さず、戻ったら数え直す
///
/// AVFoundation に依存しない値型。`MicrophoneSpeechInput` が音声のスレッドから MainActor に移して呼ぶ。
struct SpeechEventShaper: Sendable {
    var detector: VoiceActivityDetector
    var utteranceGap: Duration
    private var transcript: TranscriptAccumulator
    private var lastEndedAt: ContinuousClock.Instant?
    private(set) var isMuted = false

    init(
        detector: VoiceActivityDetector = VoiceActivityDetector(),
        cumulativeTranscripts: Bool = false,
        utteranceGap: Duration = .milliseconds(900)
    ) {
        self.detector = detector
        self.transcript = TranscriptAccumulator(cumulative: cumulativeTranscripts)
        self.utteranceGap = utteranceGap
    }

    /// 認識エンジンが決まったあとに、全文が届くエンジンかを切り替える
    mutating func useCumulativeTranscripts(_ cumulative: Bool) {
        transcript = TranscriptAccumulator(cumulative: cumulative)
    }

    var currentUtterance: String { transcript.utterance }

    /// いま話していると判定しているか
    var isVoiceActive: Bool { detector.isActive }

    mutating func level(_ rms: Float, at now: ContinuousClock.Instant) -> [SpeechInputEvent] {
        guard !isMuted else { return [] }
        switch detector.process(level: rms, at: now) {
        case .started:
            if isNewUtterance(at: now) { transcript.beginUtterance() }
            let text = transcript.utterance
            return text.isEmpty ? [.voiceStarted] : [.voiceStarted, .transcript(text)]
        case .ended:
            lastEndedAt = now
            return [.voiceEnded]
        case nil:
            return []
        }
    }

    mutating func text(_ text: String, isFinal: Bool, at now: ContinuousClock.Instant) -> [SpeechInputEvent] {
        guard !isMuted else { return [] }
        // 途中の文字を確定させるだけの結果。新しく話したことにはしない
        let confirmsVolatile = isFinal && transcript.hasVolatile
        if !confirmsVolatile, !detector.isActive, isNewUtterance(at: now) {
            transcript.beginUtterance()
        }
        guard transcript.receive(text, isFinal: isFinal) else { return [] }
        var events: [SpeechInputEvent] = []
        if !confirmsVolatile, detector.noteText(at: now) == .started {
            events.append(.voiceStarted)
        }
        let utterance = transcript.utterance
        if !utterance.isEmpty { events.append(.transcript(utterance)) }
        return events
    }

    /// ミュートを切り替える。戻ったときは、止めていた間の文字を数えない
    mutating func setMuted(_ muted: Bool) {
        guard muted != isMuted else { return }
        isMuted = muted
        detector.reset()
        lastEndedAt = nil
        if !muted { transcript.discardCurrent() }
    }

    /// 外から発話の区切りを決めたとき（「勉強スタート」を聞き取った直後など）。いままでの文字を数えない
    mutating func discardCurrentUtterance() {
        transcript.discardCurrent()
    }

    private func isNewUtterance(at now: ContinuousClock.Instant) -> Bool {
        guard let lastEndedAt else { return true }
        return now - lastEndedAt >= utteranceGap
    }
}
