import Foundation
import Testing
@testable import HomeTeacher

struct SessionFlagsTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func ツールの入力から要確認のフラグを読む() throws {
        let input: JSONValue = .object(["category": .string("bullying"), "reason": .string("学校で無視されていると話した。")])
        let flag = try #require(ParentFlagTool.parse(input, now: now))
        #expect(flag == ParentFlag(category: .bullying, reason: "学校で無視されていると話した。", createdAt: now))
    }

    @Test func self_harmのカテゴリを読む() {
        let input: JSONValue = .object(["category": .string("self_harm"), "reason": .string("x")])
        #expect(ParentFlagTool.parse(input, now: now)?.category == .selfHarm)
    }

    @Test func 知らないカテゴリやカテゴリなしはother() {
        #expect(ParentFlagTool.parse(.object(["category": .string("new_kind"), "reason": .string("x")]))?.category == .other)
        #expect(ParentFlagTool.parse(.object(["reason": .string("x")]))?.category == .other)
    }

    @Test(arguments: [
        JSONValue.object([:]),
        .object(["category": .string("health"), "reason": .string("  ")]),
        .object(["category": .string("health"), "reason": .number(1)]),
        .string("not an object"),
    ])
    func 理由がなければフラグにしない(input: JSONValue) {
        #expect(ParentFlagTool.parse(input) == nil)
    }

    @Test func セッションにフラグを記録する() {
        var flags = SessionFlags()
        #expect(!flags.hasNeedsReview)
        flags.record(ParentFlag(category: .health, reason: "頭が痛いと言った。", createdAt: now))
        #expect(flags.hasNeedsReview)
        #expect(flags.needsReview.map(\.reason) == ["頭が痛いと言った。"])
        flags.removeAll()
        #expect(!flags.hasNeedsReview)
    }

    @Test func カテゴリはツール定義のenumと揃っている() throws {
        let tool = try PromptLibrary().tool(named: ParentFlagTool.name)
        guard case .array(let values)? = tool.inputSchema["properties"]?["category"]?["enum"] else {
            Issue.record("category の enum がない")
            return
        }
        #expect(Set(values.compactMap(\.stringValue)) == Set(ParentFlag.Category.allCases.map(\.rawValue)))
    }
}

struct ToolUseAccumulatorTests {
    @Test func 分割された入力を組み立てる() {
        var acc = ToolUseAccumulator()
        acc.start(index: 1, id: "t1", name: "flag_for_parent")
        acc.append(index: 1, partialJSON: #"{"category":"hea"#)
        acc.append(index: 1, partialJSON: #"lth","reason":"お腹が痛い"}"#)
        #expect(acc.stop(index: 1) == .init(
            id: "t1", name: "flag_for_parent",
            input: .object(["category": .string("health"), "reason": .string("お腹が痛い")])
        ))
    }

    @Test func textのblockの終わりではnil() {
        var acc = ToolUseAccumulator()
        #expect(acc.stop(index: 0) == nil)
    }

    @Test func 入力が空や壊れていても空のオブジェクトで返す() {
        var acc = ToolUseAccumulator()
        acc.start(index: 0, id: "a", name: "x")
        #expect(acc.stop(index: 0)?.input == .object([:]))
        acc.start(index: 1, id: "b", name: "x")
        acc.append(index: 1, partialJSON: #"{"reason":"#)
        #expect(acc.stop(index: 1)?.input == .object([:]))
    }
}
