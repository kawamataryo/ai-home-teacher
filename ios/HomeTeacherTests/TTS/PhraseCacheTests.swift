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

    @Test func いまの声で作ったものを同梱の音声より先に使う() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // アプリ本体には ElevenLabs で作った定型句が同梱されている
        let phrases = try PhraseCache.loadManifest()
        let phrase = try #require(phrases.first)
        let bundled = try #require(PhraseCache(phrases: phrases, bundle: .main, directory: nil).speech(for: phrase))
        #expect(bundled.provider == "elevenlabs")

        let azure = SynthesizedSpeech(text: phrase.text, provider: "azure", format: .mp3, audio: Data([1, 2]), alignment: nil)
        PhraseCache(phrases: phrases, bundle: .main, directory: directory).store(azure, for: phrase)

        // Azure を使っているなら、ディスクの Azure の声を使う
        #expect(PhraseCache(phrases: phrases, bundle: .main, directory: directory, preferredProvider: "azure").speech(for: phrase) == azure)
        // ElevenLabs に戻したら、同梱の ElevenLabs の声に戻る
        #expect(PhraseCache(phrases: phrases, bundle: .main, directory: directory, preferredProvider: "elevenlabs").speech(for: phrase) == bundled)
    }

    @Test func Azureに切り替えたら同梱のElevenLabsの定型句をAzureで作り直す() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let phrases = Array(try PhraseCache.loadManifest().prefix(2))
        let azure = MockTTSProvider(identifier: "azure")
        let cache = PhraseCache(phrases: phrases, bundle: .main, directory: directory, preferredProvider: "azure")
        #expect(await cache.prepare(primary: azure, fallback: nil) == 2)

        // 次の起動では作り直さない（ディスクの Azure の声を使う）
        let next = PhraseCache(phrases: phrases, bundle: .main, directory: directory, preferredProvider: "azure")
        #expect(await next.prepare(primary: azure, fallback: nil) == 0)
        #expect(phrases.allSatisfy { next.speech(for: $0)?.provider == "azure" })
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

/// キャラごとに分ける（#120）
@MainActor
struct CharacterPhraseCacheTests {
    private static let rika = TeacherCharacter(
        id: "rika", name: "リカ", honorific: "先生", relation: .teacher, roleLine: "付き添います。", roleNoun: "家庭教師", nudgeTone: "明るく", selectable: true,
        voice: .init(azure: "ja-JP-ShioriNeural", elevenlabs: "voice-rika"), phrases: ["iine": "いいね、それ！"]
    )
    private static let koko = TeacherCharacter(
        id: "koko", name: "ココ", honorific: "先生", relation: .teacher, roleLine: "付き添います。", roleNoun: "家庭教師", nudgeTone: "明るく", selectable: true,
        voice: .init(azure: "ja-JP-NaokiNeural"), phrases: [:]
    )
    private let phrases: [PhraseCache.Phrase] = [.init(key: "iine", text: "いいね！"), .init(key: "naruhodo", text: "なるほど")]

    private func temporaryBase() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "CharacterPhraseCacheTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private func speech(_ text: String, _ marker: UInt8) -> SynthesizedSpeech {
        SynthesizedSpeech(text: text, provider: "azure", format: .mp3, audio: Data([marker]), alignment: nil)
    }

    private func cache(_ character: TeacherCharacter, base: URL) -> PhraseCache {
        PhraseCache(
            phrases: phrases, bundle: .withoutBundledPhrases, directory: PhraseCache.directory(for: character, base: base),
            preferredProvider: "azure", character: character
        )
    }

    @Test func 既定の先生の保存先は今までと同じ() {
        let base = temporaryBase()
        #expect(PhraseCache.directory(for: .haru, base: base) == base)
        #expect(PhraseCache.directory(for: Self.rika, base: base) != base)
        #expect(PhraseCache.directory(for: Self.rika, base: base) != PhraseCache.directory(for: Self.koko, base: base))
    }

    @Test func 今までに作った既定の先生のキャッシュをそのまま使う() throws {
        let base = temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let old = speech("なるほど", 9)
        // 変更前の場所（PhraseCache/<key>.json）に置いてあるもの
        try JSONEncoder().encode(old).write(to: base.appending(path: "naruhodo.json"))
        #expect(cache(.haru, base: base).speech(for: "なるほど") == old)
    }

    @Test func 別のキャラのキャッシュを再生しない() {
        let base = temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let haruSpeech = speech("なるほど", 1)
        cache(.haru, base: base).store(haruSpeech, for: .init(key: "naruhodo", text: "なるほど"))
        // ハルの音声があっても、リカとココには使わない
        #expect(cache(Self.rika, base: base).speech(for: "なるほど") == nil)
        #expect(cache(Self.koko, base: base).speech(for: "なるほど") == nil)

        let rikaSpeech = speech("なるほど", 2)
        cache(Self.rika, base: base).store(rikaSpeech, for: .init(key: "naruhodo", text: "なるほど"))
        #expect(cache(Self.rika, base: base).speech(for: "なるほど") == rikaSpeech)
        #expect(cache(.haru, base: base).speech(for: "なるほど") == haruSpeech)
        #expect(cache(Self.koko, base: base).speech(for: "なるほど") == nil)
    }

    @Test func アプリに同梱した今の先生の音声をほかのキャラに使わない() throws {
        let manifest = try PhraseCache.loadManifest()
        let phrase = try #require(manifest.first { $0.key == "naruhodo" })
        #expect(PhraseCache(phrases: manifest, bundle: .main, directory: nil).speech(for: phrase) != nil)
        #expect(PhraseCache(phrases: manifest, bundle: .main, directory: nil, character: Self.koko).speech(for: phrase) == nil)
    }

    @Test func 言い替えがあればそのキャラの文で話す() {
        let rika = cache(Self.rika, base: temporaryBase())
        #expect(rika.spokenText(for: "いいね！") == "いいね、それ！")
        #expect(rika.spokenText(for: "いいね") == "いいね、それ！")
        #expect(rika.spokenText(for: "なるほど") == "なるほど")
        #expect(rika.spokenText(for: "ふつうの文。") == "ふつうの文。")
        #expect(rika.phrase(for: "いいね、それ！")?.key == "iine")
        #expect(cache(.haru, base: temporaryBase()).spokenText(for: "いいね！") == "いいね！")
    }

    @Test func 言い替えた文と違う音声は古いものとして使わない() throws {
        let base = temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let directory = PhraseCache.directory(for: Self.rika, base: base)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(speech("いいね！", 3)).write(to: directory.appending(path: "iine.json"))
        #expect(cache(Self.rika, base: base).speech(for: "いいね！") == nil)
    }

    @Test func 初回はキャラの声で作って同じキャラのキャッシュに入れる() async {
        let base = temporaryBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let primary = MockTTSProvider(identifier: "azure")
        #expect(await cache(Self.koko, base: base).prepare(primary: primary, fallback: nil) == 2)
        #expect(cache(Self.koko, base: base).speech(for: "なるほど")?.provider == "azure")
        #expect(cache(.haru, base: base).speech(for: "なるほど") == nil)
        #expect(await cache(Self.koko, base: base).prepare(primary: primary, fallback: nil) == 0)
    }

    @Test func 声の指定をTTSに渡す() {
        let client = WorkerClient.unconfigured
        let azure = TTSProviderKind.azure.makeProvider(client: client, voice: Self.rika.voice) as? AzureTTSProvider
        #expect(azure?.voice == "ja-JP-ShioriNeural")
        let eleven = TTSProviderKind.elevenlabs.makeProvider(client: client, voice: Self.rika.voice) as? ElevenLabsTTSProvider
        #expect(eleven?.voiceID == "voice-rika")
        // 既定の先生は Worker の既定の声のまま
        #expect((TTSProviderKind.azure.makeProvider(client: client, voice: TeacherCharacter.haru.voice) as? AzureTTSProvider)?.voice == nil)
    }
}
