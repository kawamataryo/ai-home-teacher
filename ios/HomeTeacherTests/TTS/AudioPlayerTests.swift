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
