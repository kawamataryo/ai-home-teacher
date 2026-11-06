import Foundation
import Testing
@testable import HomeTeacher

/// 今の先生（既定）のプロンプトが、キャラを分ける前と同じ内容で組み上がる（#118, #119）。
/// 正解は分ける前の main で書き出した `evals/fixtures/prompts/haru/`。evals/prompt.test.mjs も同じファイルと比べる。
struct PromptGoldenTests {
    private static let directory = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "evals/fixtures/prompts/haru")

    private func golden(_ name: String) throws -> String {
        try String(contentsOf: Self.directory.appending(path: "\(name).txt"), encoding: .utf8)
    }

    /// 「そのキャラらしさ」（#122 で今の先生に足した口ぐせと抜けたところ）を除く。evals/prompt.test.mjs と揃える
    private static func withoutCharm(_ prompt: String) -> String {
        guard let start = prompt.range(of: "\n\n## そのキャラらしさ"),
              let end = prompt.range(of: "\n\n## 話し方", range: start.upperBound..<prompt.endIndex)
        else { return prompt }
        return String(prompt[..<start.lowerBound]) + String(prompt[end.lowerBound...])
    }

    // 比べるのはキャラに関わる部分だけ（teacher と声かけ）。hint_ladder など共通の部分は別の変更で変わってよい。
    @Test func 先生のプロンプトと声かけ() throws {
        let library = PromptLibrary()
        #expect(Self.withoutCharm(try library.load(.teacher)) == (try golden("teacher")))
        #expect(try library.load(.nudgeVariation) == golden("nudge_variation"))
    }

    @Test func 会話とふり返りは分ける前の先生のプロンプトから始まる() throws {
        let library = PromptLibrary()
        let start = try golden("teacher") + PromptLibrary.separator
        #expect(Self.withoutCharm(try library.conversationSystemPrompt(mode: .study)).hasPrefix(start))
        #expect(Self.withoutCharm(try SessionReflector(client: .unconfigured, library: library).systemPrompt()).hasPrefix(start))
    }
}

/// どのキャラでも、共通のルールが必ず入る（#119）
struct CharacterPromptTests {
    @Test(arguments: CharacterCatalog().characters)
    func hint_ladderとsafetyが必ず入る(character: TeacherCharacter) throws {
        let library = PromptLibrary(character: character)
        let prompt = try library.conversationSystemPrompt(mode: .study)
        #expect(prompt.contains(try library.raw(.hintLadder)))
        #expect(prompt.contains(try library.raw(.safety)))
        #expect(prompt.contains("答えをそのまま言わない"))
        #expect(prompt.contains(try library.characterProfile()))
        #expect(prompt.contains("「\(character.callName)」"))
        #expect(!prompt.contains("{{"))
        #expect(!(try library.load(.nudgeVariation)).contains("{{"))
        // ふり返りも同じキャラの話し方になる
        let reflector = SessionReflector(client: .unconfigured, library: library)
        #expect(try reflector.systemPrompt().contains(try library.characterProfile()))
    }

    @Test(arguments: CharacterCatalog().characters)
    func 先生のメモが変わっても前半は同じでキャッシュが効く(character: TeacherCharacter) throws {
        let library = PromptLibrary(character: character)
        let a = PromptLibrary.splitAtTeacherNote(try library.conversationSystemPrompt(mode: .study, teacherNote: "- 段階 1"))
        let b = PromptLibrary.splitAtTeacherNote(try library.conversationSystemPrompt(mode: .study, teacherNote: "- 段階 2"))
        #expect(a.head == b.head)
        #expect(a.tail != b.tail)
        #expect(a.head.contains(try library.characterProfile()))
    }

    @Test func キャラを替えると性格が替わる() throws {
        let catalog = CharacterCatalog()
        let haru = try PromptLibrary(character: catalog.character(id: "haru")).conversationSystemPrompt(mode: .study)
        let rika = try PromptLibrary(character: catalog.character(id: "rika")).conversationSystemPrompt(mode: .study)
        #expect(haru.contains("お兄さん先生"))
        #expect(!rika.contains("お兄さん先生"))
        #expect(rika.contains("お姉さん先生"))
    }

    @Test func 知らないキャラの性格のファイルはエラーにする() {
        let unknown = TeacherCharacter(
            id: "nobody", name: "だれ", honorific: "先生", relation: .teacher, roleLine: "付き添います。", roleNoun: "家庭教師", nudgeTone: "明るく", selectable: false
        )
        #expect(throws: PromptError.self) { try PromptLibrary(character: unknown).load(.teacher) }
    }

    @Test func 選ぶ画面には見た目までそろったキャラだけ出す() {
        let catalog = CharacterCatalog()
        #expect(catalog.selectableCharacters.contains(.haru))
        #expect(catalog.selectableCharacters.allSatisfy { $0.selectable })
    }
}
