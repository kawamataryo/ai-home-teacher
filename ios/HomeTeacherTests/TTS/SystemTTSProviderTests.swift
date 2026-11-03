import AVFoundation
import Foundation
import Testing
@testable import HomeTeacher

@MainActor
struct SystemTTSProviderTests {
    @Test func WAVのヘッダーを書く() {
        let data = WAVEncoder.encode(samples: [0, 1, -1], sampleRate: 22050)
        #expect(data.count == 44 + 6)
        #expect(String(decoding: data.prefix(4), as: UTF8.self) == "RIFF")
        #expect(String(decoding: data[8..<12], as: UTF8.self) == "WAVE")
        #expect(data[44..<46] == Data([0, 0]))
        #expect(data[46..<48] == Data([1, 0]))
    }

    @Test func 範囲ごとの開始サンプルを文字の時刻に広げる() throws {
        var state = SynthesisCollector.State()
        state.samples = Array(repeating: 0, count: 100)
        state.sampleRate = 100
        // 「いいね」は 0 サンプル目から、「！」は 60 サンプル目から
        state.spokenRanges = [.init(range: NSRange(location: 0, length: 3), frame: 0), .init(range: NSRange(location: 3, length: 1), frame: 60)]
        let alignment = try #require(SystemTTSProvider.alignment(for: "いいね！", result: state))
        #expect(alignment.characters == ["い", "い", "ね", "！"])
        #expect(alignment.characterStartTimesSeconds.map { ($0 * 100).rounded() / 100 } == [0, 0.2, 0.4, 0.6])
        #expect(alignment.characterEndTimesSeconds.last == 1)
    }

    @Test func 範囲が取れなければ均等に並べる() throws {
        var state = SynthesisCollector.State()
        state.samples = Array(repeating: 0, count: 100)
        state.sampleRate = 100
        let alignment = try #require(SystemTTSProvider.alignment(for: "あいうえ", result: state))
        #expect(alignment.characterStartTimesSeconds == [0, 0.25, 0.5, 0.75])
    }

    /// シミュレーターで実際に合成して、再生できる WAV ができるか（日本語の声がなければ飛ばす）
    @Test(.enabled(if: SystemTTSProvider.japaneseVoice() != nil, "日本語の声がない"))
    func 日本語の声で再生できる音声と文字タイミングを作る() async throws {
        let text = "こんにちは、いっしょにがんばろう。"
        let speech = try await SystemTTSProvider().synthesizeAll(text)
        #expect(speech.format == .wav)
        #expect(speech.provider == "system")
        let player = try AVAudioPlayer(data: speech.audio, fileTypeHint: speech.format.fileTypeHint)
        #expect(player.duration > 0.5)
        let alignment = try #require(speech.alignment)
        #expect(alignment.characters.joined() == text)
        // 時刻は増えていき、音声の長さに収まる
        #expect(alignment.characterStartTimesSeconds == alignment.characterStartTimesSeconds.sorted())
        #expect((alignment.characterEndTimesSeconds.last ?? 0) <= player.duration + 0.01)
        #expect(PlaybackProgress.playedCharacterCount(of: text, alignment: alignment, at: player.duration) == text.count)
    }
}
