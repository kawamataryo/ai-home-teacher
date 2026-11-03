import Foundation
import Testing
@testable import HomeTeacher

struct PromptLibraryTests {
    @Test(arguments: PromptName.allCases)
    func アプリに同梱したプロンプトを読める(name: PromptName) throws {
        // テストのホストはアプリなので Bundle.main = アプリ本体
        let text = try PromptLibrary(bundle: .main).raw(name)
        #expect(!text.isEmpty)
    }

    @Test func 先生の名前を差し込む() throws {
        let text = try PromptLibrary().load(.teacher)
        #expect(text.contains("ハル先生"))
        #expect(!text.contains("{{teacher_name}}"))

        let renamed = try PromptLibrary().load(.teacher, variables: ["teacher_name": "ミナト"])
        #expect(renamed.contains("ミナト先生"))
    }

    @Test func キャラクター設定と答えを言わないルールがある() throws {
        let text = try PromptLibrary().raw(.teacher)
        #expect(text.contains("大学生"))
        #expect(text.contains("答えをそのまま言わない"))
    }

    @Test func 見つからなければエラー() {
        #expect(throws: PromptError.notFound("nothing/teacher.md")) {
            try PromptLibrary(subdirectory: "nothing").raw(.teacher)
        }
    }

    @Test func 差し込みは知らないキーを残す() {
        #expect(PromptLibrary.render("{{a}}と{{b}}", variables: ["a": "1"]) == "1と{{b}}")
    }
}
