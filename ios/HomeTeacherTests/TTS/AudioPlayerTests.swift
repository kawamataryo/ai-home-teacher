import AVFoundation
import Foundation
import Testing
@testable import HomeTeacher

/// 440Hz の音を `seconds` 秒ぶん WAV にする
private func toneSpeech(seconds: Double, sampleRate: Int = 22050) -> SynthesizedSpeech {
    let count = Int(Double(sampleRate) * seconds)
    let samples = (0..<count).map { Int16(sin(Double($0) * 2 * .pi * 440 / Double(sampleRate)) * 8000) }
    return SynthesizedSpeech(
        text: "あ", provider: "test", format: .wav,
        audio: WAVEncoder.encode(samples: samples, sampleRate: sampleRate), alignment: nil
    )
}

@MainActor
struct AudioPlayerTests {
    @Test func WAVを決まった形式のPCMにそろえる() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let buffer = try EngineClipPlayer.decode(toneSpeech(seconds: 0.5), to: format)
        #expect(buffer.format == format)
        // 22050Hz × 0.5 秒 → 44100Hz で約 22050 フレーム
        #expect(abs(Int(buffer.frameLength) - 22050) < 600)
    }

    @Test(arguments: [false, true])
    func 再生して終わったら戻り再生中は位置が進む(usesEngine: Bool) async throws {
        let player: any SpeechAudioPlayer = usesEngine ? EngineClipPlayer(engine: AVAudioEngine()) : AudioClipPlayer()
        let clock = ContinuousClock()
        let started = clock.now
        let task = Task { try await player.play(toneSpeech(seconds: 0.4)) }
        var sawTime = false
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(20))
            if let time = player.currentTime, time > 0 { sawTime = true; break }
        }
        try await task.value
        #expect(sawTime)
        #expect(player.currentTime == nil)
        // 長さ + 1 秒の打ち切りより前に終わる
        #expect(clock.now - started < .seconds(1.4))
    }

    @Test(arguments: [false, true])
    func 止めたらすぐ戻る(usesEngine: Bool) async throws {
        let player: any SpeechAudioPlayer = usesEngine ? EngineClipPlayer(engine: AVAudioEngine()) : AudioClipPlayer()
        let clock = ContinuousClock()
        let started = clock.now
        let task = Task { try await player.play(toneSpeech(seconds: 3)) }
        try await Task.sleep(for: .milliseconds(200))
        player.stop()
        try await task.value
        #expect(player.currentTime == nil)
        #expect(clock.now - started < .seconds(1.5))
    }
}

/// ElevenLabs の MP3（ヘッダーなしのフレーム列）がそのまま再生できるか
@MainActor
struct MP3PlaybackTests {
    private func mp3(_ audio: Data) -> SynthesizedSpeech {
        SynthesizedSpeech(text: "あ", provider: "elevenlabs", format: .mp3, audio: audio, alignment: nil)
    }

    @Test func AVAudioPlayerがヘッダーなしのMP3を読める() throws {
        let player = try AVAudioPlayer(data: MP3Fixture.tone, fileTypeHint: TTSAudioFormat.mp3.fileTypeHint)
        #expect(player.duration > 0.2)
        // チャンクをつなげただけのものも読める
        let doubled = try AVAudioPlayer(data: MP3Fixture.tone + MP3Fixture.tone, fileTypeHint: TTSAudioFormat.mp3.fileTypeHint)
        #expect(doubled.duration > player.duration * 1.5)
    }

    @Test func EngineClipPlayerがMP3をPCMにできる() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let buffer = try EngineClipPlayer.decode(mp3(MP3Fixture.tone + MP3Fixture.tone), to: format)
        #expect(Double(buffer.frameLength) / 44_100 > 0.5)
    }

    @Test func Workerから2つに分かれて届いたMP3をまとめて再生できる() async throws {
        let bytes = MP3Fixture.tone
        let mid = bytes.count / 2
        let body = [
            elevenLabsChunkJSON(audio: bytes.prefix(mid), alignment: evenAlignment("あい")),
            elevenLabsChunkJSON(audio: bytes.suffix(from: mid), alignment: evenAlignment("う", offset: 0.2)),
        ].joined(separator: "\n")
        let provider = ElevenLabsTTSProvider(
            client: WorkerClient(baseURL: URL(string: "https://example.workers.dev")!, familyToken: "t", transport: MockTransport(body: body))
        )
        let speech = try await provider.synthesizeAll("あいう")
        #expect(speech.audio == bytes)
        let player = try AVAudioPlayer(data: speech.audio, fileTypeHint: speech.format.fileTypeHint)
        #expect(player.duration > 0.2)
        // 実際に最後まで再生して戻る
        try await AudioClipPlayer().play(speech)
    }
}
