import Foundation
import Testing
@testable import HomeTeacher

struct SchemaDefaultsTests {
    private func decode(_ json: String) -> BoardContent {
        BoardTools.content(toolName: BoardTools.showBoardName, input: Data(json.utf8))
    }

    @Test func 足りないキーは既定値で埋めて部品として読む() {
        // strict ではないので、ranges や unit が抜けた入力も来る
        let content = decode(#"{"title":"数直線","component":{"type":"number_line","min":0,"max":10,"step":1,"marks":[{"value":3}]}}"#)
        guard case .component(let title, .numberLine(let line)) = content else {
            Issue.record("部品として読めなかった: \(content)")
            return
        }
        #expect(title == "数直線")
        #expect(line.unit == "")
        #expect(line.ranges == [])
        #expect(line.marks == [.init(value: 3, label: "")])
    }

    @Test func 型が違う値は読めれば直す() {
        let content = decode(#"{"component":{"type":"bar_chart","unit":"冊","bars":[{"label":4,"value":"120","highlighted":"true"}]}}"#)
        guard case .component(let title, .barChart(let chart)) = content else {
            Issue.record("部品として読めなかった: \(content)")
            return
        }
        #expect(title == "")
        #expect(chart.bars == [.init(label: "4", value: 120, highlighted: true)])
    }

    @Test func 知らない部品は文字の代わりにする() {
        let content = decode(#"{"title":"ベン図","component":{"type":"venn_unknown","sets":["犬","ねこ"]}}"#)
        guard case .text(let text) = content else {
            Issue.record("文字にならなかった: \(content)")
            return
        }
        #expect(text.contains("ベン図"))
    }

    @Test func 余分なキーは残してもデコードに影響しない() {
        let schema = Schema.object([("a", Schema.string("a"))])
        let filled = SchemaDefaults.fill(.object(["a": .string("x"), "extra": .number(1)]), schema: schema)
        #expect(filled == .object(["a": .string("x"), "extra": .number(1)]))
        #expect(SchemaDefaults.fill(nil, schema: schema) == .object(["a": .string("")]))
    }
}
