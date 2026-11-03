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

    @Test func 会話用はteacherとhint_ladderとsafetyをこの順につなぐ() throws {
        let library = PromptLibrary()
        let prompt = try library.conversationSystemPrompt()
        let parts = prompt.components(separatedBy: PromptLibrary.separator)
        #expect(parts == [try library.load(.teacher), try library.load(.hintLadder), try library.load(.safety)])
        #expect(!prompt.contains("先生のメモ（子どもには"))
    }

    @Test func 先生のメモは最後に足す() throws {
        let prompt = try PromptLibrary().conversationSystemPrompt(teacherNote: "- 正答: 48冊\n")
        let last = try #require(prompt.components(separatedBy: PromptLibrary.separator).last)
        #expect(last.hasPrefix("# 先生のメモ"))
        #expect(last.hasSuffix("- 正答: 48冊"))
    }

    @Test func 空の先生のメモは足さない() throws {
        let library = PromptLibrary()
        #expect(try library.conversationSystemPrompt(teacherNote: "  \n") == library.conversationSystemPrompt())
    }

    @Test func 安全ルールにspecの項目がある() throws {
        let text = try PromptLibrary().raw(.safety)
        for keyword in ["個人情報", "お父さんやお母さん", "いじめ", "医療・心理"] {
            #expect(text.contains(keyword), "\(keyword) がない")
        }
    }

    @Test func ヒントの段階に問題の種類がある() throws {
        let text = try PromptLibrary().raw(.hintLadder)
        for keyword in ["reading", "thinking", "writing", "何を聞かれているか", "どこを見れば", "考え方の方向", "一緒に解き方をたどる"] {
            #expect(text.contains(keyword), "\(keyword) がない")
        }
    }

    @Test func 部品カタログにspecの部品がすべてある() throws {
        let text = try PromptLibrary().boardCatalog()
        let components = ["step_cards", "number_line", "area_diagram", "segment_diagram", "table",
                          "bar_chart", "highlight_image", "essay_outline", "render_svg", "show_board"]
        for name in components {
            #expect(text.contains(name), "\(name) がない")
        }
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
