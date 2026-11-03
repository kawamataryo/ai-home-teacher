import AVFoundation
import Foundation

/// 音声データの形式。AVAudioPlayer に渡すときのヒントに使う
enum TTSAudioFormat: String, Codable, Sendable {
    /// ElevenLabs の既定（mp3_44100_128）。チャンクをつなげただけの MP3 フレーム列
    case mp3
    /// SystemTTSProvider が作る 16bit モノラルの WAV
    case wav

    var fileTypeHint: String {
        switch self {
        case .mp3: AVFileType.mp3.rawValue
        case .wav: AVFileType.wav.rawValue
        }
    }
}

/// TTS のストリームで届く 1 かたまり。音声と文字タイミングのどちらかが空のこともある
struct TTSChunk: Equatable, Sendable {
    var audio: Data
    var alignment: TTSAlignment?

    init(audio: Data, alignment: TTSAlignment? = nil) {
        self.audio = audio
        self.alignment = alignment
    }
}

/// 1 文ぶんの、再生できる音声
struct SynthesizedSpeech: Codable, Equatable, Sendable {
    /// 読み上げた文
    var text: String
    /// 作った TTS（`TTSProvider.identifier`）。定型句キャッシュの作り直しの判断に使う
    var provider: String
    var format: TTSAudioFormat
    var audio: Data
    /// 文字タイミング（音声の先頭からの秒）。取れなかったら nil
    var alignment: TTSAlignment?
}

enum TTSError: Error, Equatable {
    /// 音声が 1 バイトも届かなかった
    case noAudio
    /// ストリームの JSON が読めなかった
    case invalidChunk(String)
    /// 上流（ElevenLabs）がエラーを返した
    case upstream(String)
    /// 日本語の声が見つからない
    case voiceUnavailable
    /// 時間内に音声ができなかった
    case timedOut
    /// 再生できなかった
    case playbackFailed
}

/// 読み上げの差し替え口（ElevenLabs / AVSpeechSynthesizer / テスト用のモック）
@MainActor
protocol TTSProvider: Sendable {
    /// キャッシュのキーなどに使う名前（"elevenlabs" / "system"）
    var identifier: String { get }
    var format: TTSAudioFormat { get }
    /// 1 文を音声にする。音声と文字タイミングを届いた順に流す。止めたいときはストリームの受け取りをやめる
    func synthesize(_ text: String) -> AsyncThrowingStream<TTSChunk, Error>
}

extension TTSProvider {
    /// ストリームを最後まで受け取って、1 文ぶんの音声にまとめる
    func synthesizeAll(_ text: String) async throws -> SynthesizedSpeech {
        var audio = Data()
        var merger = TTSAlignmentMerger()
        for try await chunk in synthesize(text) {
            audio.append(chunk.audio)
            if let alignment = chunk.alignment { merger.append(alignment) }
        }
        // 受け取りの途中で止められたら、ストリームは何も言わずに終わる
        try Task.checkCancellation()
        guard !audio.isEmpty else { throw TTSError.noAudio }
        return SynthesizedSpeech(text: text, provider: identifier, format: format, audio: audio, alignment: merger.merged)
    }
}

/// `operation` が `timeout` までに終わらなければ `TTSError.timedOut` を投げる（`operation` は取り消す）
///
/// `operation` は取り消されたら投げる（または終わる）こと。呼び出し側が取り消されたら `operation` も取り消す。
@MainActor
func withTTSTimeout<T: Sendable>(
    _ timeout: Duration,
    _ operation: @escaping @MainActor @Sendable () async throws -> T
) async throws -> T {
    let work = Task { @MainActor in try await operation() }
    let expired = TimeoutFlag()
    let timer = Task { @MainActor in
        try await Task.sleep(for: timeout)
        expired.value = true
        work.cancel()
    }
    defer { timer.cancel() }
    return try await withTaskCancellationHandler {
        do {
            return try await work.value
        } catch {
            if expired.value { throw TTSError.timedOut }
            throw error
        }
    } onCancel: {
        work.cancel()
    }
}

@MainActor
private final class TimeoutFlag {
    var value = false
}
