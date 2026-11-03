import AVFoundation
import Foundation

/// Azure Neural TTS（Worker の /v1/tts/azure 経由）。音声は MP3（24kHz モノラル）
///
/// Azure の REST は文字タイミングを返さないので、音声の長さを文字数で均等に割って推定する
/// （口パクと、割り込みで何文字目まで話したかの両方に使う）。
struct AzureTTSProvider: TTSProvider {
    let client: WorkerClient
    /// nil なら Worker の既定の声（AZURE_TTS_VOICE）
    let voice: String?

    let identifier = "azure"
    let format = TTSAudioFormat.mp3

    init(client: WorkerClient, voice: String? = nil) {
        self.client = client
        self.voice = voice
    }

    struct RequestBody: Encodable, Equatable {
        var text: String
        var voice: String?
    }

    func synthesize(_ text: String) -> AsyncThrowingStream<TTSChunk, Error> {
        let client = client
        let body = RequestBody(text: text, voice: voice)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // 1 文ぶんをまとめて受け取る（再生も 1 文を受け取りきってから始めるので、流して受ける利点がない）
                    let audio = try await client.postJSON(path: "/v1/tts/azure", body: body)
                    guard !audio.isEmpty else { throw TTSError.noAudio }
                    let duration = (try? AVAudioPlayer(data: audio, fileTypeHint: TTSAudioFormat.mp3.fileTypeHint).duration) ?? 0
                    continuation.yield(TTSChunk(audio: audio, alignment: TTSAlignment.evenlySpaced(text, duration: duration)))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // 受け手が止めたら（割り込みなど）通信も止める
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension TTSAlignment {
    /// 文字ごとの時刻が取れない TTS 用: `duration` 秒を文字数で均等に割る。文が空か長さが 0 なら nil
    static func evenlySpaced(_ text: String, duration: TimeInterval) -> TTSAlignment? {
        let characters = text.map(String.init)
        guard !characters.isEmpty, duration > 0 else { return nil }
        let step = duration / Double(characters.count)
        let starts = characters.indices.map { Double($0) * step }
        let ends = characters.indices.map { Double($0 + 1) * step }
        return TTSAlignment(characters: characters, characterStartTimesSeconds: starts, characterEndTimesSeconds: ends)
    }
}
