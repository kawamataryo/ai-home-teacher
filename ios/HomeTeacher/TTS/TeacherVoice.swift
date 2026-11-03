import Foundation
import OSLog

/// 先生の声。1 文を音声にして再生し、口パク（LipSyncPlayer）を再生位置に合わせて動かす
///
/// - 定型句キャッシュにある文は、合成せずにすぐ再生する
/// - まず `primary`（ElevenLabs）で作る。失敗するか `primaryTimeout` までにできなければ `fallback`（AVSpeechSynthesizer）
/// - `stop()` で止めると、その文の何文字目まで話したかを返す（割り込み #13 で発言を切る位置）。数えるのは文ごと
@MainActor
final class TeacherVoice: SpeechOutput {
    enum Outcome: Equatable, Sendable {
        /// 最後まで話した
        case completed
        /// `stop()` で止めた。`playedCharacters` 文字目まで話していた（合成中に止めたら 0）
        case stopped(playedCharacters: Int)
        /// どの TTS でも音声を作れなかった、または再生できなかった
        case failed
    }

    private let primary: any TTSProvider
    private let fallback: (any TTSProvider)?
    private let player: any SpeechAudioPlayer
    private let lipSync: LipSyncPlayer
    private let phraseCache: PhraseCache?
    var primaryTimeout: Duration
    /// `primary` が失敗したら、この間は `primary` を使わずに `fallback` で話す（#66。つながらない Worker を 1 文ごとに待たない）
    var primaryCooldown: Duration = .seconds(60)
    private var primaryFailedAt: ContinuousClock.Instant?

    /// 話している文と音声（再生中だけ）
    private var current: (text: String, speech: SynthesizedSpeech)?
    /// `say` ごとに増やす。止めたあとに古い `say` が再生を始めたり、後片付けをしたりしないようにする
    private var generation = 0
    private var synthesisTask: Task<SynthesizedSpeech, Error>?
    private var stoppedPlayedCharacters = 0
    private let logger = Logger(subsystem: "com.kawamataryo.HomeTeacher", category: "TeacherVoice")

    init(
        primary: any TTSProvider,
        fallback: (any TTSProvider)? = nil,
        player: any SpeechAudioPlayer,
        lipSync: LipSyncPlayer,
        phraseCache: PhraseCache? = nil,
        primaryTimeout: Duration = .seconds(6)
    ) {
        self.primary = primary
        self.fallback = fallback
        self.player = player
        self.lipSync = lipSync
        self.phraseCache = phraseCache
        self.primaryTimeout = primaryTimeout
    }

    /// 合成中か再生中
    private(set) var isSpeaking = false

    /// 再生中の文の、いま何文字目まで話したか（Swift の Character 単位）。再生していなければ 0
    var playedCharacterCount: Int {
        guard let current, let time = player.currentTime else { return 0 }
        return PlaybackProgress.playedCharacterCount(
            of: current.text, alignment: current.speech.alignment, at: time, duration: player.duration
        )
    }

    func speak(_ text: String) async {
        await say(text)
    }

    /// 1 文を話して、終わったら（または止められたら）戻る
    @discardableResult
    func say(_ text: String) async -> Outcome {
        generation += 1
        let id = generation
        isSpeaking = true
        defer { if id == generation { isSpeaking = false } }

        let speech: SynthesizedSpeech
        if let cached = phraseCache?.speech(for: text) {
            speech = cached
        } else {
            let task = Task { @MainActor in try await self.synthesize(text) }
            synthesisTask = task
            let result = await task.result
            guard id == generation else { return .stopped(playedCharacters: 0) }
            synthesisTask = nil
            switch result {
            case .success(let made):
                speech = made
                // 定型句ならキャッシュにも入れておく
                if let phrase = phraseCache?.phrase(for: text) { phraseCache?.store(made, for: phrase) }
            case .failure(let error):
                logger.error("音声を作れなかった: \(String(describing: error), privacy: .public)")
                return .failed
            }
        }

        current = (text, speech)
        if let alignment = speech.alignment {
            let player = player
            lipSync.play(LipSyncConverter.timeline(from: alignment), clock: { [weak player] in player?.currentTime })
        } else {
            lipSync.stop()
        }

        do {
            try await player.play(speech)
        } catch {
            guard id == generation else { return .stopped(playedCharacters: stoppedPlayedCharacters) }
            logger.error("再生できなかった: \(String(describing: error), privacy: .public)")
            current = nil
            lipSync.stop()
            return .failed
        }
        guard id == generation else { return .stopped(playedCharacters: stoppedPlayedCharacters) }
        current = nil
        lipSync.stop()
        return .completed
    }

    /// いまの文を止める。何文字目まで話していたかを返す（合成中・何も話していなければ 0）
    @discardableResult
    func stop() -> Int {
        // player を止める前に数える（止めると再生位置が取れなくなる）
        let played = playedCharacterCount
        generation += 1
        stoppedPlayedCharacters = played
        synthesisTask?.cancel()
        synthesisTask = nil
        current = nil
        isSpeaking = false
        player.stop()
        lipSync.stop()
        return played
    }

    private func synthesize(_ text: String) async throws -> SynthesizedSpeech {
        let primary = primary
        if let fallback, let failedAt = primaryFailedAt, ContinuousClock.now - failedAt < primaryCooldown {
            return try await fallback.synthesizeAll(text)
        }
        do {
            let speech = try await withTTSTimeout(primaryTimeout) { try await primary.synthesizeAll(text) }
            primaryFailedAt = nil
            return speech
        } catch {
            // 止められたら予備にも行かない
            if Task.isCancelled { throw CancellationError() }
            guard let fallback else { throw error }
            primaryFailedAt = .now
            logger.info("\(primary.identifier, privacy: .public) が使えないので \(fallback.identifier, privacy: .public) で話す: \(String(describing: error), privacy: .public)")
            return try await fallback.synthesizeAll(text)
        }
    }
}
