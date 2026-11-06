import Foundation
import Observation

/// 選ぶ画面で話す声（`TeacherVoice` と同じ）
@MainActor
protocol CharacterIntroVoice: AnyObject {
    @discardableResult func stopSpeaking() -> Int
    func speakLine(_ text: String) async
}

extension TeacherVoice: CharacterIntroVoice {
    func stopSpeaking() -> Int { stop() }
    func speakLine(_ text: String) async { _ = await say(text) }
}

/// 選ぶ画面のもと（#123）。触ると自己紹介を 1 人分だけ話す。連打しても重ならない
@MainActor
@Observable
final class CharacterPickerModel {
    let characters: [TeacherCharacter]
    /// いま見ているキャラ
    private(set) var focused: TeacherCharacter
    /// 話しているキャラの id
    private(set) var speakingID: String?
    /// 選んであいさつしているところ
    private(set) var isGreeting = false
    /// いまの先生の id
    private(set) var currentID: String
    /// 吹き出しに出す言葉。最後に話した言葉を残す（あいさつのあと閉じるまで自己紹介に戻さない）
    private(set) var line: String

    @ObservationIgnored private let voice: any CharacterIntroVoice
    /// 話す前に、声をそのキャラのものに替える
    @ObservationIgnored private let useVoice: (TeacherCharacter) -> Void
    @ObservationIgnored private let save: (String) -> Void
    @ObservationIgnored private var generation = 0

    init(
        characters: [TeacherCharacter], selected: TeacherCharacter,
        voice: any CharacterIntroVoice, useVoice: @escaping (TeacherCharacter) -> Void, save: @escaping (String) -> Void
    ) {
        self.characters = characters
        let first = characters.contains(selected) ? selected : (characters.first ?? selected)
        focused = first
        currentID = selected.id
        line = first.intro
        self.voice = voice
        self.useVoice = useVoice
        self.save = save
    }

    /// キャラに触った。前の声を止めて、そのキャラの自己紹介を話す
    func meet(_ character: TeacherCharacter) async {
        guard !isGreeting else { return }
        focused = character
        await speak(character.intro, as: character)
    }

    /// 選ぶ。保存して、そのキャラの声であいさつする
    func choose(_ character: TeacherCharacter) async {
        guard !isGreeting else { return }
        isGreeting = true
        focused = character
        save(character.id)
        currentID = character.id
        await speak(character.greeting, as: character)
        isGreeting = false
    }

    /// 閉じるときに声を止める
    func close() {
        generation += 1
        speakingID = nil
        voice.stopSpeaking()
    }

    private func speak(_ line: String, as character: TeacherCharacter) async {
        generation += 1
        let id = generation
        // 声を替えると、いま話している文は止まる
        voice.stopSpeaking()
        useVoice(character)
        speakingID = character.id
        self.line = line
        await voice.speakLine(line)
        // 別のキャラに触っていたら、あとのキャラの「話している」を消さない
        if id == generation { speakingID = nil }
    }
}
