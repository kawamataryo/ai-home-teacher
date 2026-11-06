import Foundation
import Testing
@testable import HomeTeacher

@MainActor
struct CharacterPickerModelTests {
    private static let haru = CharacterCatalog().character(id: "haru")
    private static let rika = CharacterCatalog().character(id: "rika")

    private let player = MockAudioPlayer()
    private let lipSync = LipSyncPlayer()

    private func make(saved: @escaping (String) -> Void = { _ in }) -> (CharacterPickerModel, TeacherVoice, MockTTSProvider, MockTTSProvider, () -> [String]) {
        let haruVoice = MockTTSProvider(identifier: "haru-voice")
        let rikaVoice = MockTTSProvider(identifier: "rika-voice")
        let voice = TeacherVoice(primary: haruVoice, player: player, lipSync: lipSync)
        let box = StartedBox()
        voice.onPlaybackStart = { text, provider in box.values.append("\(provider):\(text)") }
        let model = CharacterPickerModel(
            characters: [Self.haru, Self.rika], selected: Self.haru, voice: voice,
            useVoice: { [weak voice] character in
                voice?.use(primary: character.id == "rika" ? rikaVoice : haruVoice, phraseCache: nil)
            },
            save: saved
        )
        return (model, voice, haruVoice, rikaVoice, { box.values })
    }

    @Test func 触ると自分の声で自己紹介を話す() async {
        let (model, _, _, _, started) = make()
        let task = Task { await model.meet(Self.rika) }
        await player.waitUntilPlaying(count: 1)
        #expect(model.focused == Self.rika)
        #expect(model.speakingID == "rika")
        player.finish()
        await task.value
        #expect(model.speakingID == nil)
        #expect(started() == ["rika-voice:\(Self.rika.intro)"])
    }

    @Test func 連打しても声が重ならず最後の1人分だけ話す() async {
        let (model, voice, _, _, started) = make()
        var tasks: [Task<Void, Never>] = []
        for character in [Self.haru, Self.rika, Self.haru, Self.rika, Self.rika] {
            tasks.append(Task { await model.meet(character) })
            await Task.yield()
        }
        // いちばん新しいものだけ再生中になる
        await player.waitUntilPlaying(count: 1)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(voice.isSpeaking)
        #expect(player.maxActiveCount <= 1)
        #expect(model.speakingID == "rika")
        player.finish()
        for task in tasks { await task.value }
        #expect(model.speakingID == nil)
        #expect(started().last == "rika-voice:\(Self.rika.intro)")
        #expect(player.activeCount == 0)
    }

    @Test func 選ぶと保存してあいさつする() async {
        var saved: [String] = []
        let (model, _, _, _, started) = make(saved: { saved.append($0) })
        let task = Task { await model.choose(Self.rika) }
        await player.waitUntilPlaying(count: 1)
        #expect(model.isGreeting)
        // あいさつの間は、別のキャラに触っても切り替えない
        await model.meet(Self.haru)
        #expect(model.focused == Self.rika)
        player.finish()
        await task.value
        #expect(saved == ["rika"])
        #expect(started() == ["rika-voice:\(Self.rika.greeting)"])
        #expect(!model.isGreeting)
    }

    @Test func 閉じると声を止める() async {
        let (model, voice, _, _, _) = make()
        let task = Task { await model.meet(Self.haru) }
        await player.waitUntilPlaying(count: 1)
        model.close()
        await task.value
        #expect(!voice.isSpeaking)
        #expect(model.speakingID == nil)
    }

    @Test func どのキャラにも自己紹介とあいさつがある() {
        for character in CharacterCatalog().characters {
            #expect(!character.intro.isEmpty, "\(character.id)")
            #expect(!character.greeting.isEmpty, "\(character.id)")
            #expect(!character.tagline.isEmpty, "\(character.id)")
            // 自己紹介は短く（1〜2 文）
            let sentences = character.intro.filter { $0 == "。" }.count
            #expect(sentences >= 1 && sentences <= 2, "\(character.id)")
        }
    }

    @Test func 自己紹介の定型句も同じキャラのキャッシュに入る() throws {
        let cache = try PhraseCache(bundle: .main, directory: nil, character: Self.rika)
        #expect(cache.phrase(for: Self.rika.intro)?.key == "intro")
        #expect(cache.phrase(for: Self.haru.intro) == nil)
    }

    @Test func 口パクは選ぶ画面と学習の画面で同じものを使っても途切れない() async throws {
        // つなぎ先に頼らず、それぞれのモデルに口の形が入る
        let first = try await TeacherModel.load()
        try await first.preloadFaceTextures()
        let second = try await RiggedModel.load(name: "proto_rig")
        let a = AvatarAnimator(model: first)
        let b = RiggedAnimator(model: second)
        let player = LipSyncPlayer()
        a.lipSync = player
        b.lipSync = player
        player.play(LipSyncConverter.timeline(from: LipSyncDemo.alignment(for: "あああ"))) { 0.05 }
        a.update(deltaTime: 1.0 / 60)
        b.update(deltaTime: 1.0 / 60)
        #expect(second.mouth == .a)
    }
}

@MainActor
private final class StartedBox {
    var values: [String] = []
}

/// 替えても記憶は共通（#123）
struct CharacterSwitchMemoryTests {
    @Test func キャラを替えても前回のことがプロンプトに入る() async throws {
        let previous = "## 前回の勉強（昨日）\n\n割合の問題を自分で解けた"
        for id in ["haru", "rika"] {
            let library = PromptLibrary(character: CharacterCatalog().character(id: id))
            let prompt = try library.conversationSystemPrompt(mode: .study, previousSession: previous)
            #expect(prompt.contains("割合の問題を自分で解けた"), "\(id)")
        }
    }
}

@MainActor
struct CharacterChoiceTests {
    private func defaults() -> UserDefaults {
        let name = "CharacterChoiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func 次のセッションのプロンプトが選んだキャラになる() async throws {
        let store = defaults()
        let preferences = SessionPreferences(defaults: store)
        preferences.characterID = "rika"
        #expect(SessionPreferences(defaults: store).selectedCharacter.id == "rika")
        let prompt = try PromptLibrary(character: preferences.selectedCharacter).conversationSystemPrompt()
        #expect(prompt.contains("「リカ先生」"))
    }
}
