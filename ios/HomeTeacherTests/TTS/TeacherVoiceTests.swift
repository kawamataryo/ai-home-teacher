import Foundation
import Testing
@testable import HomeTeacher

@MainActor
struct TeacherVoiceTests {
    private let player = MockAudioPlayer()
    private let lipSync = LipSyncPlayer()

    private func voice(
        primary: any TTSProvider,
        fallback: (any TTSProvider)? = nil,
        cache: PhraseCache? = nil,
        timeout: Duration = .seconds(5)
    ) -> TeacherVoice {
        TeacherVoice(primary: primary, fallback: fallback, player: player, lipSync: lipSync, phraseCache: cache, primaryTimeout: timeout)
    }

    @Test func 文を順番に合成して再生し口パクを再生位置に合わせる() async {
        let primary = MockTTSProvider(identifier: "eleven")
        let voice = voice(primary: primary)

        let first = Task { await voice.say("はい") }
        await player.waitUntilPlaying(count: 1)
        #expect(voice.isSpeaking)
        // 「は」の真ん中 → あ、「い」の真ん中 → い
        player.time = 0.05
        #expect(lipSync.update() == .a)
        player.time = 0.15
        #expect(lipSync.update() == .i)
        #expect(voice.playedCharacterCount == 2)
        player.finish()
        #expect(await first.value == .completed)
        #expect(lipSync.currentShape == .closed)
        #expect(!voice.isSpeaking)

        let second = Task { await voice.say("つぎ") }
        await player.waitUntilPlaying(count: 2)
        player.finish()
        #expect(await second.value == .completed)

        #expect(primary.requests == ["はい", "つぎ"])
        #expect(player.played.map(\.text) == ["はい", "つぎ"])
        #expect(player.played.map(\.provider) == ["eleven", "eleven"])
    }

    @Test func SpeechOutputとして文ごとに終わるまで待つ() async {
        let voice = voice(primary: MockTTSProvider())
        let output: any SpeechOutput = voice
        var finished = false
        let task = Task {
            await output.speak("いち")
            finished = true
        }
        await player.waitUntilPlaying()
        #expect(!finished)
        player.finish()
        await task.value
        #expect(finished)
    }

    @Test func 再生中に止めると話した文字数を返す() async {
        let voice = voice(primary: MockTTSProvider())
        let task = Task { await voice.say("あいうえお") }
        await player.waitUntilPlaying()
        player.time = 0.25

        #expect(voice.stop() == 3)
        #expect(await task.value == .stopped(playedCharacters: 3))
        #expect(lipSync.currentShape == .closed)
        #expect(!voice.isSpeaking)

        // 止めたあとも次の文はふつうに話せる
        let next = Task { await voice.say("つぎ") }
        await player.waitUntilPlaying(count: 2)
        player.finish()
        #expect(await next.value == .completed)
    }

    @Test func 合成中に止めたら再生しない() async {
        let primary = MockTTSProvider(behavior: .hang)
        let voice = voice(primary: primary, fallback: MockTTSProvider(identifier: "system"))
        let task = Task { await voice.say("まって") }
        while primary.requests.isEmpty { await Task.yield() }

        #expect(voice.stop() == 0)
        #expect(await task.value == .stopped(playedCharacters: 0))
        #expect(player.played.isEmpty)
    }

    @Test func Workerがエラーなら予備のTTSで話す() async {
        let transport = MockTransport(status: 502, body: #"{"error":"upstream unreachable"}"#)
        let eleven = ElevenLabsTTSProvider(
            client: WorkerClient(baseURL: URL(string: "https://example.workers.dev")!, familyToken: "t", transport: transport)
        )
        let system = MockTTSProvider(identifier: "system")
        let voice = voice(primary: eleven, fallback: system)

        let task = Task { await voice.say("だいじょうぶ") }
        await player.waitUntilPlaying()
        player.finish()
        #expect(await task.value == .completed)
        #expect(system.requests == ["だいじょうぶ"])
        #expect(player.played.map(\.provider) == ["system"])
    }

    @Test func Workerが返事をしなければ時間切れで予備のTTSで話す() async {
        let transport = HangingTransport(lines: [])
        let eleven = ElevenLabsTTSProvider(
            client: WorkerClient(baseURL: URL(string: "https://example.workers.dev")!, familyToken: "t", transport: transport)
        )
        let system = MockTTSProvider(identifier: "system")
        let voice = voice(primary: eleven, fallback: system, timeout: .milliseconds(50))

        let task = Task { await voice.say("おそいね") }
        await player.waitUntilPlaying()
        player.finish()
        #expect(await task.value == .completed)
        #expect(player.played.map(\.provider) == ["system"])
    }

    @Test func ストリームの途中で失敗したら予備のTTSで文を作り直す() async {
        // 1 チャンク届いたあと、壊れた JSON で終わる
        let body = elevenLabsChunkJSON(audio: Data([1]), alignment: evenAlignment("あ")) + "\n" + #"{"audio_base64":"#
        let eleven = ElevenLabsTTSProvider(
            client: WorkerClient(baseURL: URL(string: "https://example.workers.dev")!, familyToken: "t", transport: MockTransport(body: body))
        )
        let system = MockTTSProvider(identifier: "system")
        let voice = voice(primary: eleven, fallback: system)

        let task = Task { await voice.say("あいう") }
        await player.waitUntilPlaying()
        player.finish()
        #expect(await task.value == .completed)
        #expect(player.played.count == 1)
        #expect(player.played.first?.provider == "system")
    }

    @Test func どのTTSも使えなければfailed() async {
        let voice = voice(primary: MockTTSProvider(behavior: .fail(TTSError.noAudio)),
                          fallback: MockTTSProvider(behavior: .fail(TTSError.voiceUnavailable)))
        #expect(await voice.say("あ") == .failed)
        #expect(player.played.isEmpty)
        #expect(!voice.isSpeaking)
    }

    @Test func 定型句はキャッシュの音声をすぐ再生する() async {
        let cache = PhraseCache(phrases: [.init(key: "iine", text: "いいね！")], bundle: .withoutBundledPhrases, directory: nil)
        let cached = SynthesizedSpeech(text: "いいね！", provider: "elevenlabs", format: .mp3, audio: Data([9]), alignment: evenAlignment("いいね！"))
        cache.store(cached, for: .init(key: "iine", text: "いいね！"))
        let primary = MockTTSProvider()
        let voice = voice(primary: primary, cache: cache)

        let task = Task { await voice.say("いいね") }
        await player.waitUntilPlaying()
        player.finish()
        #expect(await task.value == .completed)
        #expect(primary.requests.isEmpty)
        #expect(player.played == [cached])
    }

    @Test func キャッシュにない定型句は合成してキャッシュに入れる() async {
        let phrase = PhraseCache.Phrase(key: "doredore", text: "どれどれ")
        let cache = PhraseCache(phrases: [phrase], bundle: .withoutBundledPhrases, directory: nil)
        let primary = MockTTSProvider()
        let voice = voice(primary: primary, cache: cache)

        let first = Task { await voice.say("どれどれ") }
        await player.waitUntilPlaying()
        player.finish()
        _ = await first.value
        let second = Task { await voice.say("どれどれ") }
        await player.waitUntilPlaying(count: 2)
        player.finish()
        _ = await second.value

        #expect(primary.requests == ["どれどれ"])
        #expect(cache.speech(for: phrase)?.provider == "mock")
    }

    @Test func 鳴らし始めるたびに話す文を知らせる() async {
        let cache = PhraseCache(phrases: [.init(key: "iine", text: "いいね！")], bundle: .withoutBundledPhrases, directory: nil)
        cache.store(
            SynthesizedSpeech(text: "いいね！", provider: "elevenlabs", format: .mp3, audio: Data([9]), alignment: nil),
            for: .init(key: "iine", text: "いいね！")
        )
        let voice = voice(primary: MockTTSProvider(), cache: cache)
        var started: [String] = []
        var providers: [String] = []
        voice.onPlaybackStart = { text, provider in
            started.append(text)
            providers.append(provider)
        }

        // キャッシュの定型句も、合成した文も、再生が終わる前に知らせる（音声を作った TTS も）
        let first = Task { await voice.say("いいね！") }
        await player.waitUntilPlaying()
        #expect(started == ["いいね！"])
        player.finish()
        _ = await first.value
        let second = Task { await voice.say("つぎの文") }
        await player.waitUntilPlaying(count: 2)
        #expect(started == ["いいね！", "つぎの文"])
        #expect(providers == ["elevenlabs", "mock"])
        player.finish()
        _ = await second.value
    }

    @Test func 音声を作れなければ話し始めたことにしない() async {
        let voice = voice(primary: MockTTSProvider(behavior: .fail(TTSError.noAudio)))
        var started: [String] = []
        voice.onPlaybackStart = { text, _ in started.append(text) }
        #expect(await voice.say("あ") == .failed)
        #expect(started.isEmpty)
    }
}

/// キャラを替えると、話す文と定型句の両方が同じ声になる（#120）
@MainActor
struct TeacherVoiceCharacterTests {
    private let player = MockAudioPlayer()
    private let lipSync = LipSyncPlayer()
    private static let rika = TeacherCharacter(
        id: "rika", name: "リカ", honorific: "先生", relation: .teacher, roleLine: "付き添います。", roleNoun: "家庭教師", nudgeTone: "明るく", selectable: true,
        voice: .init(azure: "ja-JP-ShioriNeural"), phrases: ["iine": "いいね、それ！"]
    )
    private let phrases: [PhraseCache.Phrase] = [.init(key: "iine", text: "いいね！"), .init(key: "naruhodo", text: "なるほど")]

    private func phraseCache(_ character: TeacherCharacter) -> PhraseCache {
        PhraseCache(phrases: phrases, bundle: .withoutBundledPhrases, directory: nil, character: character)
    }

    @Test func キャラを替えると文も定型句も新しい声で作る() async {
        let haruVoice = MockTTSProvider(identifier: "haru-voice")
        let rikaVoice = MockTTSProvider(identifier: "rika-voice")
        let voice = TeacherVoice(primary: haruVoice, player: player, lipSync: lipSync, phraseCache: phraseCache(.haru))

        var started: [(String, String)] = []
        voice.onPlaybackStart = { started.append(($0, $1)) }

        let first = Task { await voice.say("なるほど") }
        await player.waitUntilPlaying(count: 1)
        player.finish()
        _ = await first.value

        voice.use(primary: rikaVoice, phraseCache: phraseCache(Self.rika))
        let second = Task { await voice.say("なるほど") }
        await player.waitUntilPlaying(count: 2)
        player.finish()
        _ = await second.value
        // 言い替えのある定型句は、そのキャラの文で話す
        let third = Task { await voice.say("いいね！") }
        await player.waitUntilPlaying(count: 3)
        player.finish()
        _ = await third.value
        let fourth = Task { await voice.say("ふつうの文です。") }
        await player.waitUntilPlaying(count: 4)
        player.finish()
        _ = await fourth.value

        #expect(started.map(\.1) == ["haru-voice", "rika-voice", "rika-voice", "rika-voice"])
        #expect(started.map(\.0) == ["なるほど", "なるほど", "いいね、それ！", "ふつうの文です。"])
    }

    @Test func オフラインなら端末の声に落ちて止まらない() async {
        let failing = MockTTSProvider(identifier: "rika-voice", behavior: .fail(TTSError.upstream("offline")))
        let system = MockTTSProvider(identifier: "system")
        let voice = TeacherVoice(primary: failing, fallback: system, player: player, lipSync: lipSync, phraseCache: phraseCache(Self.rika))
        let task = Task { await voice.say("なるほど") }
        await player.waitUntilPlaying(count: 1)
        player.finish()
        #expect(await task.value == .completed)
    }
}
