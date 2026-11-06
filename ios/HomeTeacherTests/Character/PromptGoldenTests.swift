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

    /// 書き出した日（2026年11月6日）
    private var today: Date {
        var parts = DateComponents()
        parts.year = 2026; parts.month = 11; parts.day = 6; parts.hour = 12
        parts.timeZone = TimeZone(identifier: "Asia/Tokyo")
        return Calendar(identifier: .gregorian).date(from: parts)!
    }

    @Test func 会話_勉強中() throws {
        #expect(try PromptLibrary().conversationSystemPrompt(mode: .study, today: today) == golden("conversation_study"))
    }

    @Test func 会話_休憩中_前回のことと先生のメモあり() throws {
        let prompt = try PromptLibrary().conversationSystemPrompt(
            mode: .rest, teacherNote: "- 正答: 40", previousSession: "## 前回の勉強（昨日）\n\n割合の問題", today: today
        )
        #expect(prompt == (try golden("conversation_rest_full")))
    }

    @Test func ふり返りと言いかえ() throws {
        let library = PromptLibrary()
        let reflection = [try library.load(.teacher), try library.load(.reflection)].joined(separator: PromptLibrary.separator)
        #expect(reflection == (try golden("reflection_system")))
        #expect(try library.load(.nudgeVariation) == golden("nudge_variation"))
    }
}
