import Foundation
import Testing
@testable import HomeTeacher

struct BoardToolsTests {
    @Test(arguments: BoardComponent.Kind.allCases)
    func サンプルJSONがその部品として読める(kind: BoardComponent.Kind) throws {
        guard case .component(let title, let component) = BoardSamples.content(kind) else {
            Issue.record("文字の代替表示になった: \(kind)")
            return
        }
        #expect(!title.isEmpty)
        #expect(component.kind == kind)
    }

    @Test func ツール定義はstrictで全部品を含む() throws {
        let tool = BoardTools.showBoard
        #expect(tool["name"] == .string("show_board"))
        #expect(tool["strict"] == .bool(true))
        #expect(tool["description"]?.stringValue?.contains("正答") == true)
        let input = try #require(tool["input_schema"])
        #expect(input["type"] == .string("object"))

        guard case .array(let branches)? = input["properties"]?["component"]?["anyOf"] else {
            Issue.record("component が anyOf になっていない")
            return
        }
        let types = branches.compactMap { $0["properties"]?["type"]?["const"]?.stringValue }
        #expect(types == BoardComponent.Kind.allCases.map(\.rawValue))
    }

    @Test func 全オブジェクトがadditionalPropertiesなしで全キー必須() {
        var objects = 0
        func walk(_ node: JSONValue, path: String) {
            switch node {
            case .object(let o):
                if o["type"] == .string("object") {
                    objects += 1
                    #expect(o["additionalProperties"] == .bool(false), "\(path)")
                    guard case .object(let props)? = o["properties"], case .array(let req)? = o["required"] else {
                        Issue.record("properties / required が無い: \(path)")
                        return
                    }
                    #expect(Set(req.compactMap(\.stringValue)) == Set(props.keys), "\(path)")
                }
                // strict 非対応のキーワードを使っていない
                for banned in ["minimum", "maximum", "minLength", "maxLength", "multipleOf", "oneOf"] {
                    #expect(o[banned] == nil, "\(path).\(banned)")
                }
                for (k, v) in o { walk(v, path: "\(path).\(k)") }
            case .array(let a):
                for (i, v) in a.enumerated() { walk(v, path: "\(path)[\(i)]") }
            default:
                break
            }
        }
        walk(BoardTools.showBoard, path: "show_board")
        #expect(objects > BoardComponent.Kind.allCases.count)
    }

    /// Swift のモデルにフィールドを足して Schema を直し忘れたら、ここで落ちる。
    @Test(arguments: BoardComponent.Kind.allCases)
    func モデルを書き出したJSONがスキーマと一致する(kind: BoardComponent.Kind) throws {
        let data = Data(BoardSamples.json[kind]!.utf8)
        let decoded = try BoardTools.makeDecoder().decode(ShowBoardInput.self, from: data)
        let encoded = try JSONDecoder().decode(JSONValue.self, from: try BoardTools.makeEncoder().encode(decoded))
        let original = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(encoded == original, "読み書きで中身が変わった")
        let errors = SchemaChecker.validate(encoded, against: ShowBoardInput.schema)
        #expect(errors.isEmpty, "\(errors)")
    }

    @Test(arguments: [
        #"{"title":"x","component":{"type":"pie_chart","note":"円グラフ"}}"#,
        #"{"title":"x","component":{"type":"bar_chart","unit":"人"}}"#,
        #"{"title":"x","component":{"type":"table","headers":"だめ","rows":[],"highlight_cells":[]}}"#,
        #"["配列だけ"]"#,
        #""ただの文字""#,
        "{こわれた",
        "",
    ])
    func 読めない入力は文字で出す(input: String) {
        let content = BoardTools.content(toolName: BoardTools.showBoardName, input: Data(input.utf8))
        guard case .text(let text) = content else {
            Issue.record("部品として読めてしまった: \(input)")
            return
        }
        #expect(!text.isEmpty)
    }

    @Test func 代替表示は見出しを先に出し種類の名前は出さない() {
        let content = BoardTools.content(toolName: BoardTools.showBoardName, input: Data(BoardSamples.brokenJSON.utf8))
        guard case .text(let text) = content else {
            Issue.record("文字になっていない")
            return
        }
        let lines = text.split(separator: "\n")
        #expect(lines.first == "この図は読めない")
        #expect(lines.contains("円グラフで半分が赤"))
        #expect(!text.contains("pie_chart"))
    }

    @Test func 知らないツール名は文字で出す() {
        let content = BoardTools.content(toolName: "unknown_tool", input: Data(BoardSamples.json[.stepCards]!.utf8))
        guard case .text = content else {
            Issue.record("文字になっていない")
            return
        }
    }

    @Test func tools配列のJSONを書き出せる() throws {
        let data = try BoardTools.toolsJSON()
        let parsed = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        #expect(parsed?.first?["name"] as? String == "show_board")
        // キー順が固定（プロンプトキャッシュのため）
        #expect(try BoardTools.toolsJSON() == data)
    }
}

/// テスト用の小さな JSON Schema 検査（このアプリで使う部分だけ）。
enum SchemaChecker {
    static func validate(_ value: JSONValue, against schema: JSONValue, path: String = "$") -> [String] {
        if case .array(let branches)? = schema["anyOf"] {
            let results = branches.map { validate(value, against: $0, path: path) }
            return results.contains { $0.isEmpty } ? [] : ["\(path): どの anyOf にも合わない \(results)"]
        }
        if let c = schema["const"], value != c { return ["\(path): const \(c) でない"] }
        switch (schema["type"]?.stringValue, value) {
        case ("object", .object(let o)):
            guard case .object(let props)? = schema["properties"] else { return ["\(path): properties が無い"] }
            var errors: [String] = []
            if Set(o.keys) != Set(props.keys) {
                errors.append("\(path): キーが違う \(o.keys.sorted()) / \(props.keys.sorted())")
            }
            for (k, v) in o {
                if let s = props[k] { errors += validate(v, against: s, path: "\(path).\(k)") }
            }
            return errors
        case ("array", .array(let a)):
            guard let items = schema["items"] else { return ["\(path): items が無い"] }
            return a.enumerated().flatMap { validate($1, against: items, path: "\(path)[\($0)]") }
        case ("string", .string), ("boolean", .bool), ("number", .number):
            return []
        case ("integer", .number(let n)):
            return n == n.rounded() ? [] : ["\(path): 整数でない"]
        default:
            return ["\(path): 型が違う \(String(describing: schema["type"])) / \(value)"]
        }
    }
}
