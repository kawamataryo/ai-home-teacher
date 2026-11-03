import Foundation
@testable import HomeTeacher

/// 1 文字 `step` 秒ずつの文字タイミング
func evenAlignment(_ text: String, step: Double = 0.1, offset: Double = 0) -> TTSAlignment {
    let characters = text.map(String.init)
    return TTSAlignment(
        characters: characters,
        characterStartTimesSeconds: characters.indices.map { offset + Double($0) * step },
        characterEndTimesSeconds: characters.indices.map { offset + Double($0 + 1) * step }
    )
}

/// ElevenLabs の `stream/with-timestamps` の 1 オブジェクト
func elevenLabsChunkJSON(audio: Data, alignment: TTSAlignment?) -> String {
    var object: [String: Any] = ["audio_base64": audio.base64EncodedString()]
    if let alignment {
        object["alignment"] = [
            "characters": alignment.characters,
            "character_start_times_seconds": alignment.characterStartTimesSeconds,
            "character_end_times_seconds": alignment.characterEndTimesSeconds,
        ]
        object["normalized_alignment"] = object["alignment"]
    }
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

/// 決まった音声を返す（または失敗する・終わらない）TTS
@MainActor
final class MockTTSProvider: TTSProvider {
    enum Behavior {
        /// 文ごとに 1 チャンク（音声は文の UTF-8、1 文字 0.1 秒のタイミング）
        case succeed
        case fail(Error)
        /// 何も返さず終わらない（取り消されるまで）
        case hang
    }

    let identifier: String
    let format = TTSAudioFormat.mp3
    var behavior: Behavior
    private(set) var requests: [String] = []
    /// hang のときに持っておく（ストリームが勝手に終わらないように）
    private var hanging: [AsyncThrowingStream<TTSChunk, Error>.Continuation] = []

    init(identifier: String = "mock", behavior: Behavior = .succeed) {
        self.identifier = identifier
        self.behavior = behavior
    }

    func synthesize(_ text: String) -> AsyncThrowingStream<TTSChunk, Error> {
        requests.append(text)
        let (stream, continuation) = AsyncThrowingStream<TTSChunk, Error>.makeStream()
        switch behavior {
        case .succeed:
            continuation.yield(TTSChunk(audio: Data("\(identifier):\(text)".utf8), alignment: evenAlignment(text)))
            continuation.finish()
        case .fail(let error):
            continuation.finish(throwing: error)
        case .hang:
            hanging.append(continuation)
        }
        return stream
    }
}

/// 手で進める再生。`finish()` を呼ぶまで再生が終わらない。`time` が再生位置
@MainActor
final class MockAudioPlayer: SpeechAudioPlayer {
    private(set) var played: [SynthesizedSpeech] = []
    private(set) var stopCount = 0
    var time: TimeInterval = 0
    var clipDuration: TimeInterval = 1
    var failsToPlay = false
    private var isPlaying = false
    private var playing: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    var currentTime: TimeInterval? { isPlaying ? time : nil }
    var duration: TimeInterval? { isPlaying ? clipDuration : nil }

    func play(_ speech: SynthesizedSpeech) async throws {
        if failsToPlay { throw TTSError.playbackFailed }
        played.append(speech)
        time = 0
        isPlaying = true
        let waiters = startWaiters
        startWaiters = []
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { playing = $0 }
    }

    /// `count` 個目の再生が始まるまで待つ
    func waitUntilPlaying(count: Int = 1) async {
        while played.count < count {
            await withCheckedContinuation { startWaiters.append($0) }
        }
    }

    /// 最後まで再生した
    func finish() {
        isPlaying = false
        playing?.resume()
        playing = nil
    }

    func stop() {
        stopCount += 1
        finish()
    }
}
