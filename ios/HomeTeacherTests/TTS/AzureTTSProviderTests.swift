import AVFoundation
import Foundation
import Testing
@testable import HomeTeacher

@MainActor
struct AzureTTSProviderTests {
    private func provider(_ transport: MockTransport, voice: String? = nil) -> AzureTTSProvider {
        AzureTTSProvider(
            client: WorkerClient(baseURL: URL(string: "https://example.workers.dev")!, familyToken: "t", transport: transport),
            voice: voice
        )
    }

    @Test func Workerのazureに文を送ってMP3と推定の文字タイミングを受け取る() async throws {
        let transport = MockTransport(responses: [.init(body: "", bytes: MP3Fixture.tone)])
        let speech = try await provider(transport).synthesizeAll("あいう")

        let request = try #require(await transport.requests.first)
        #expect(request.url?.path() == "/v1/tts/azure")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer t")
        let body = try #require(request.httpBody)
        #expect(try JSONSerialization.jsonObject(with: body) as? [String: String] == ["text": "あいう"])

        #expect(speech.provider == "azure")
        #expect(speech.format == .mp3)
        #expect(speech.audio == MP3Fixture.tone)
        // 音声の長さ（約 0.3 秒）を 3 文字で均等に割る
        let alignment = try #require(speech.alignment)
        let duration = try AVAudioPlayer(data: MP3Fixture.tone, fileTypeHint: AVFileType.mp3.rawValue).duration
        #expect(alignment.characters == ["あ", "い", "う"])
        #expect(alignment.characterStartTimesSeconds.first == 0)
        #expect(abs((alignment.characterEndTimesSeconds.last ?? 0) - duration) < 1e-9)
        #expect(abs(alignment.characterStartTimesSeconds[1] - duration / 3) < 1e-9)
        // 再生できる
        try await AudioClipPlayer().play(speech)
    }

    @Test func 声を指定すると本文に入る() async throws {
        let transport = MockTransport(responses: [.init(body: "", bytes: MP3Fixture.tone)])
        _ = try await provider(transport, voice: "ja-JP-AoiNeural").synthesizeAll("はい")
        let body = try #require(await transport.requests.first?.httpBody)
        #expect(try JSONSerialization.jsonObject(with: body) as? [String: String] == ["text": "はい", "voice": "ja-JP-AoiNeural"])
    }

    @Test func 上流の429はエラーにする() async {
        let transport = MockTransport(status: 429, body: "")
        await #expect(throws: WorkerError.http(status: 429, body: "")) {
            try await provider(transport).synthesizeAll("はい")
        }
    }

    @Test func 本文が空なら音声なしのエラー() async {
        let transport = MockTransport(responses: [.init(body: "", bytes: Data())])
        await #expect(throws: TTSError.noAudio) {
            try await provider(transport).synthesizeAll("はい")
        }
    }

    @Test func 均等割りの文字タイミング() throws {
        let alignment = try #require(TTSAlignment.evenlySpaced("いいね", duration: 0.9))
        #expect(alignment.characters == ["い", "い", "ね"])
        #expect(alignment.characterStartTimesSeconds.map { ($0 * 10).rounded() / 10 } == [0, 0.3, 0.6])
        #expect(alignment.characterEndTimesSeconds.map { ($0 * 10).rounded() / 10 } == [0.3, 0.6, 0.9])
        #expect(TTSAlignment.evenlySpaced("", duration: 1) == nil)
        #expect(TTSAlignment.evenlySpaced("はい", duration: 0) == nil)
    }
}

@MainActor
struct TTSProviderKindTests {
    @Test(arguments: [
        (nil as String?, TTSProviderKind.elevenlabs),
        ("", .elevenlabs),
        ("elevenlabs", .elevenlabs),
        ("azure", .azure),
        (" Azure ", .azure),
        ("unknown", .elevenlabs),
    ])
    func 設定の値から選ぶ(setting: String?, expected: TTSProviderKind) {
        #expect(TTSProviderKind(setting: setting) == expected)
    }

    @Test func 選んだTTSのidentifierは名前と同じ() {
        let client = WorkerClient(baseURL: URL(string: "https://example.workers.dev")!, familyToken: "t", transport: MockTransport(body: ""))
        for kind in TTSProviderKind.allCases {
            #expect(kind.makeProvider(client: client).identifier == kind.rawValue)
        }
    }
}
