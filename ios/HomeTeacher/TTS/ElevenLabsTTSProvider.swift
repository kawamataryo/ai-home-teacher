import Foundation

/// ElevenLabs Flash v2.5（Worker の /v1/tts 経由）。音声は MP3（ElevenLabs の既定 mp3_44100_128）で、文字タイミング付き
struct ElevenLabsTTSProvider: TTSProvider {
    let client: WorkerClient
    /// nil なら Worker の既定の声（ELEVENLABS_VOICE_ID）
    let voiceID: String?

    let identifier = "elevenlabs"
    let format = TTSAudioFormat.mp3

    init(client: WorkerClient, voiceID: String? = nil) {
        self.client = client
        self.voiceID = voiceID
    }

    struct RequestBody: Encodable, Equatable {
        var text: String
        var voiceID: String?

        enum CodingKeys: String, CodingKey {
            case text
            case voiceID = "voice_id"
        }
    }

    func synthesize(_ text: String) -> AsyncThrowingStream<TTSChunk, Error> {
        let client = client
        let body = RequestBody(text: text, voiceID: voiceID)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // URLSession の lines は改行で区切るだけ。改行なしでくっついたオブジェクトはパーサーが切り分ける
                    let lines = try await client.streamLines(path: "/v1/tts", body: body)
                    var parser = ElevenLabsStreamParser()
                    for try await line in lines {
                        for chunk in try parser.feed(line) {
                            continuation.yield(chunk)
                        }
                    }
                    try parser.finish()
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
