import Foundation
import Testing
@testable import HomeTeacher

@MainActor
struct PhraseCacheTests {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "PhraseCacheTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @Test func 同梱の一覧に10個以上あってタイマーの定型句をすべて含む() throws {
        // テストのホストはアプリなので Bundle.main = アプリ本体
        let phrases = try PhraseCache.loadManifest()
        #expect(phrases.count >= 10)
        #expect(Set(phrases.map(\.key)).count == phrases.count)
        for fixed in FixedPhrase.allCases {
            #expect(phrases.contains(.init(key: fixed.rawValue, text: fixed.text)), "\(fixed)")
        }
        for text in ["いいね！", "どれどれ", "お、いい感じ！", "そうそう！", "なるほど", "すごいじゃん！", "もう一回言ってみて", "ちょっと見せて？"] {
            #expect(phrases.contains { $0.text == text }, "\(text)")
        }
    }

    @Test func 文末の句読点と空白を無視して引く() {
        let cache = PhraseCache(phrases: [.init(key: "iine", text: "いいね！"), .init(key: "doredore", text: "お、どれどれ…")], bundle: .withoutBundledPhrases, directory: nil)
        #expect(cache.phrase(for: "いいね")?.key == "iine")
        #expect(cache.phrase(for: " いいね！！ ")?.key == "iine")
        #expect(cache.phrase(for: "お、どれどれ")?.key == "doredore")
        #expect(cache.phrase(for: "いいねえ") == nil)
        #expect(cache.phrase(for: "") == nil)
        // 音声がまだなければ nil
        #expect(cache.speech(for: "いいね") == nil)
    }

    @Test func ディスクに保存して次の起動で読める() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let phrase = PhraseCache.Phrase(key: "iine", text: "いいね！")
        let speech = SynthesizedSpeech(text: "いいね！", provider: "system", format: .wav, audio: Data([1, 2]), alignment: evenAlignment("いいね！"))
        PhraseCache(phrases: [phrase], bundle: .withoutBundledPhrases, directory: directory).store(speech, for: phrase)

        let reopened = PhraseCache(phrases: [phrase], bundle: .withoutBundledPhrases, directory: directory)
        #expect(reopened.speech(for: "いいね") == speech)

        // 一覧の文が変わったら古い音声は使わない
        let edited = PhraseCache(phrases: [.init(key: "iine", text: "いいねえ！")], bundle: .withoutBundledPhrases, directory: directory)
        #expect(edited.speech(for: "いいねえ") == nil)
    }

    @Test func 初回に足りない定型句を作り予備の声のものはあとで作り直す() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let phrases: [PhraseCache.Phrase] = [.init(key: "a", text: "いいね"), .init(key: "b", text: "なるほど")]

        // オフライン: ElevenLabs が失敗するので予備の声で作る
        let offline = MockTTSProvider(identifier: "elevenlabs", behavior: .fail(URLError(.notConnectedToInternet)))
        let system = MockTTSProvider(identifier: "system")
        let cache = PhraseCache(phrases: phrases, bundle: .withoutBundledPhrases, directory: directory)
        #expect(await cache.prepare(primary: offline, fallback: system) == 2)
        #expect(cache.speech(for: "なるほど")?.provider == "system")

        // オンラインになったら ElevenLabs で作り直す。ElevenLabs のものがあれば作らない
        let online = MockTTSProvider(identifier: "elevenlabs")
        let next = PhraseCache(phrases: phrases, bundle: .withoutBundledPhrases, directory: directory)
        #expect(await next.prepare(primary: online, fallback: system) == 2)
        #expect(next.speech(for: "なるほど")?.provider == "elevenlabs")
        #expect(await next.prepare(primary: online, fallback: system) == 0)
        #expect(online.requests == ["いいね", "なるほど"])
    }

    @Test func scriptsのgenerate_phrasesが書く形式を読める() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // generate_phrases.mjs と同じキー（audio は base64、alignment は ElevenLabs の形）
        let json = """
        {"text":"いいね！","provider":"elevenlabs","format":"mp3","audio":"\(MP3Fixture.tone.base64EncodedString())",\
        "alignment":{"characters":["い","い","ね","！"],"character_start_times_seconds":[0,0.1,0.2,0.3],\
        "character_end_times_seconds":[0.1,0.2,0.3,0.4]}}
        """
        try Data(json.utf8).write(to: directory.appending(path: "iine.json"))

        let cache = PhraseCache(phrases: [.init(key: "iine", text: "いいね！")], bundle: .withoutBundledPhrases, directory: directory)
        let speech = try #require(cache.speech(for: "いいね！"))
        #expect(speech.format == .mp3)
        #expect(speech.audio == MP3Fixture.tone)
        #expect(speech.alignment?.characters == ["い", "い", "ね", "！"])
    }

    @Test func オフラインなら最初の失敗のあとはすぐ予備の声で作る() async {
        let phrases = (0..<5).map { PhraseCache.Phrase(key: "p\($0)", text: "ことば\($0)") }
        let offline = MockTTSProvider(identifier: "elevenlabs", behavior: .fail(URLError(.notConnectedToInternet)))
        let system = MockTTSProvider(identifier: "system")
        let cache = PhraseCache(phrases: phrases, bundle: .withoutBundledPhrases, directory: nil)
        #expect(await cache.prepare(primary: offline, fallback: system) == 5)
        #expect(offline.requests.count == 1)
        #expect(system.requests.count == 5)
    }
}
