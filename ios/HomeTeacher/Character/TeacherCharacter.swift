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

    let id: String
    /// 名前（「ハル」）
    let name: String
    /// 子どもからの呼ばれ方（「ハル先生」。仲間なら「ソラ」）
    let callName: String
    let relation: Relation

    /// プロンプトに差し込む値
    var promptVariables: [String: String] {
        ["teacher_name": name]
    }

    /// 既定の先生。一覧を読めないときや、選択がないときもこの先生にする
    static let haru = TeacherCharacter(id: "haru", name: "ハル", callName: "ハル先生", relation: .teacher)
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

    /// `id` のキャラ。nil や知らない id（消したキャラ・壊れた保存値）なら既定の先生
    func character(id: String?) -> TeacherCharacter {
        characters.first { $0.id == id } ?? defaultCharacter
    }
}
