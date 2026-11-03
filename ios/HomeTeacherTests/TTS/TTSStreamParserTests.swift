import Foundation
import Testing
@testable import HomeTeacher

struct JSONObjectStreamScannerTests {
    @Test func 改行区切りでもくっついていても切り出せる() {
        var scanner = JSONObjectStreamScanner()
        let objects = scanner.feed(Data(#"{"a":1}"#.utf8) + Data("\n".utf8) + Data(#"{"b":2}{"c":{"d":3}}"#.utf8))
        #expect(objects.map { String(decoding: $0, as: UTF8.self) } == [#"{"a":1}"#, #"{"b":2}"#, #"{"c":{"d":3}}"#])
    }

    @Test func 文字列の中のかっこと引用符とエスケープは数えない() {
        var scanner = JSONObjectStreamScanner()
        let text = #"{"characters":["{","}","\"","\\","あ"]}"#
        let objects = scanner.feed(Data(text.utf8))
        #expect(objects.map { String(decoding: $0, as: UTF8.self) } == [text])
        #expect(!scanner.hasPartialObject)
    }

    @Test func 途中で切れていたら次に持ち越す() {
        var scanner = JSONObjectStreamScanner()
        #expect(scanner.feed(Data(#"{"a":"x{"#.utf8)).isEmpty)
        #expect(scanner.hasPartialObject)
        let objects = scanner.feed(Data(#"y"}"#.utf8))
        #expect(objects.map { String(decoding: $0, as: UTF8.self) } == [#"{"a":"x{y"}"#])
    }
}

struct ElevenLabsStreamParserTests {
    /// アラインメントに { } " \ が入った 3 チャンク
    private let fixture: [(text: String, json: String)] = {
        let texts = ["いいね{", "\"そう\\", "}だね！"]
        var offset = 0.0
        return texts.map { text in
            let alignment = evenAlignment(text, offset: offset)
            offset += Double(text.count) * 0.1
            return (text, elevenLabsChunkJSON(audio: Data(text.utf8), alignment: alignment))
        }
    }()

    private func parseAll(_ pieces: [String]) throws -> [TTSChunk] {
        var parser = ElevenLabsStreamParser()
        var chunks: [TTSChunk] = []
        for piece in pieces { chunks += try parser.feed(piece) }
        try parser.finish()
        return chunks
    }

    @Test func 改行区切りの本文を読む() throws {
        let chunks = try parseAll([fixture.map(\.json).joined(separator: "\n") + "\n"])
        #expect(chunks.map { String(decoding: $0.audio, as: UTF8.self) } == fixture.map(\.text))
        #expect(chunks.map { $0.alignment?.characters.joined() } == fixture.map(\.text))
    }

    @Test func くっついた本文をどこで切って届いても同じに読める() throws {
        let body = fixture.map(\.json).joined()
        let expected = try parseAll([body])
        #expect(expected.count == 3)
        let bytes = Array(body.utf8)
        // 1 バイトずつずらして 2 つに切る（UTF-8 の文字の途中で切れることもある）
        for cut in 1..<bytes.count {
            var parser = ElevenLabsStreamParser()
            var chunks = try parser.feed(Data(bytes[..<cut]))
            chunks += try parser.feed(Data(bytes[cut...]))
            try parser.finish()
            #expect(chunks == expected, "cut at \(cut)")
        }
    }

    @Test func 音声だけのチャンクとタイミングだけのチャンクも受け取る() throws {
        let chunks = try parseAll([
            #"{"audio_base64":"AAEC","alignment":null}"#,
            #"{"audio_base64":null,"alignment":{"characters":["あ"],"character_start_times_seconds":[0],"character_end_times_seconds":[0.1]}}"#,
            #"{"audio_base64":""}"#,
        ])
        #expect(chunks.count == 2)
        #expect(chunks[0].audio == Data([0, 1, 2]))
        #expect(chunks[0].alignment == nil)
        #expect(chunks[1].audio.isEmpty)
        #expect(chunks[1].alignment?.characters == ["あ"])
    }

    @Test func 上流のエラーは投げる() {
        var parser = ElevenLabsStreamParser()
        #expect(throws: TTSError.self) {
            _ = try parser.feed(#"{"detail":{"status":"quota_exceeded"}}"#)
        }
    }

    @Test func オブジェクトの途中で終わったら投げる() throws {
        var parser = ElevenLabsStreamParser()
        _ = try parser.feed(#"{"audio_base64":"AA"#)
        #expect(throws: TTSError.self) { try parser.finish() }
    }
}

@MainActor
struct ElevenLabsTTSProviderTests {
    private func provider(_ transport: some HTTPTransport) -> ElevenLabsTTSProvider {
        ElevenLabsTTSProvider(
            client: WorkerClient(baseURL: URL(string: "https://example.workers.dev")!, familyToken: "token", transport: transport),
            voiceID: "voice-1"
        )
    }

    @Test(arguments: ["\n", ""])
    func Workerのストリームを1文の音声にまとめる(separator: String) async throws {
        // 2 つめのチャンクの時刻は「チャンクの先頭から」のつもりで 0 から
        let body = [
            elevenLabsChunkJSON(audio: Data([1, 2]), alignment: evenAlignment("いい")),
            elevenLabsChunkJSON(audio: Data([3]), alignment: evenAlignment("ね！")),
        ].joined(separator: separator)
        let transport = MockTransport(body: body)
        let speech = try await provider(transport).synthesizeAll("いいね！")

        #expect(speech.audio == Data([1, 2, 3]))
        #expect(speech.format == .mp3)
        #expect(speech.provider == "elevenlabs")
        let alignment = try #require(speech.alignment)
        #expect(alignment.characters == ["い", "い", "ね", "！"])
        #expect(alignment.characterStartTimesSeconds.map { ($0 * 10).rounded() / 10 } == [0, 0.1, 0.2, 0.3])

        let request = try #require(await transport.requests.first)
        #expect(request.url?.path == "/v1/tts")
        let sent = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: String]
        #expect(sent == ["text": "いいね！", "voice_id": "voice-1"])
    }

    @Test func Workerがエラーを返したら投げる() async {
        let transport = MockTransport(status: 502, body: #"{"error":"upstream unreachable"}"#)
        await #expect(throws: WorkerError.http(status: 502, body: #"{"error":"upstream unreachable"}"#)) {
            _ = try await provider(transport).synthesizeAll("いいね")
        }
    }
}
