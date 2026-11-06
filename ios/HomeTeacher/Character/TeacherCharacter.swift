import Foundation

/// 子どもが選ぶ「自分の先生」1人ぶんの定義（#117）。
///
/// 一覧は `prompts/characters/characters.json`。アプリと `evals/prompt.mjs` が同じファイルを読む。
struct TeacherCharacter: Codable, Identifiable, Equatable, Sendable {
    /// 先生か、一緒にがんばる仲間か
    enum Relation: String, Codable, Sendable {
        case teacher
        case companion
    }

    /// 声の指定。nil なら Worker の既定の声（今の先生）
    struct Voice: Codable, Equatable, Sendable {
        var azure: String?
        var elevenlabs: String?
    }

    let id: String
    /// 名前（「ハル」）
    let name: String
    /// 名前のあとの呼び方（「先生」。仲間なら空）
    let honorific: String
    let relation: Relation
    /// プロンプトの「小学5年生の子どもの家庭学習に、」に続く1文
    let roleLine: String
    /// 声かけのプロンプトでの役目の言い方（「家庭教師」）
    let roleNoun: String
    /// 声かけの言い回しの調子
    let nudgeTone: String
    /// 選ぶ画面に出すか（見た目までそろったら true にする）
    let selectable: Bool
    /// 声（#120）
    var voice = Voice()
    /// 定型句の言い替え（定型句の key → 文）。書いていない定型句は共通の文のまま話す
    var phrases: [String: String] = [:]
    /// 見た目（#121）
    var look = CharacterLook.haru

    /// 子どもからの呼ばれ方（「ハル先生」。仲間なら「ソラ」）
    var callName: String { name + honorific }

    /// プロンプトに差し込む値。evals/prompt.mjs の characterVariables と揃える
    var promptVariables: [String: String] {
        ["teacher_name": name, "honorific": honorific, "role_line": roleLine, "role_noun": roleNoun, "nudge_tone": nudgeTone]
    }

    /// 既定の先生。一覧を読めないときや、選択がないときもこの先生にする
    static let haru = TeacherCharacter(
        id: "haru", name: "ハル", honorific: "先生", relation: .teacher,
        roleLine: "iPad の向こうから付き添う先生です。", roleNoun: "家庭教師", nudgeTone: "やさしく、明るく", selectable: true,
        voice: Voice(), phrases: [:]
    )
}

/// キャラの一覧。選択がない・知らないキャラのときは既定の先生に戻す。
struct CharacterCatalog: Sendable {
    static let manifestName = "characters"
    static let manifestSubdirectory = "prompts/characters"

    let characters: [TeacherCharacter]

    /// 既定の先生を必ず含める（一覧の先頭に置く）
    init(characters: [TeacherCharacter]) {
        let others = characters.filter { $0.id != TeacherCharacter.haru.id }
        let haru = characters.first { $0.id == TeacherCharacter.haru.id } ?? .haru
        self.characters = [haru] + others
    }

    /// 同梱の一覧を読む。読めなければ既定の先生だけにする（会話を止めない）
    init(bundle: Bundle = .main) {
        guard let url = bundle.url(forResource: Self.manifestName, withExtension: "json", subdirectory: Self.manifestSubdirectory),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([TeacherCharacter].self, from: data)
        else {
            self.init(characters: [.haru])
            return
        }
        self.init(characters: decoded)
    }

    var defaultCharacter: TeacherCharacter { characters[0] }

    /// 選ぶ画面に出すキャラ
    var selectableCharacters: [TeacherCharacter] { characters.filter(\.selectable) }

    /// `id` のキャラ。nil や知らない id（消したキャラ・壊れた保存値）なら既定の先生
    func character(id: String?) -> TeacherCharacter {
        characters.first { $0.id == id } ?? defaultCharacter
    }
}
