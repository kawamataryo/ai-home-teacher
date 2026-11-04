import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import HomeTeacher

/// 自由に描く黒板（#107）
struct ChalkDrawingTests {
    private func content(_ shapes: String, title: String = "図") -> BoardContent {
        let json = #"{"title":"\#(title)","component":{"type":"chalk_drawing","shapes":\#(shapes)}}"#
        return BoardTools.content(toolName: BoardTools.showBoardName, input: Data(json.utf8))
    }

    private func drawing(_ content: BoardContent) -> ChalkDrawing? {
        guard case .component(_, .chalkDrawing(let m)) = content else { return nil }
        return m
    }

    @Test func 使わないキーを省いても読める() throws {
        let m = try #require(drawing(content(#"[{"kind":"arrow","points":[[10,10],[50,10]]},{"kind":"stamp","stamp":"beaker","points":[[30,40]]}]"#)))
        #expect(m.shapes.count == 2)
        #expect(m.shapes[0].parsedKind == .arrow)
        #expect(m.shapes[0].color == "" && !m.shapes[0].dashed && m.shapes[0].scale == 1)
        #expect(m.shapes[1].parsedStamp == .beaker)
        #expect(m.shapes[1].revealStep == 1)
    }

    @Test func 部品が文字列のJSONで返ってきても読める() throws {
        let inner = #"{"type":"chalk_drawing","shapes":"[{\"kind\":\"circle\",\"points\":[[50,30]],\"radius\":8}]"}"#
        let input = try JSONValue.object(["title": .string("円"), "component": .string(inner)]).jsonData()
        let m = try #require(drawing(BoardTools.content(toolName: BoardTools.showBoardName, input: input)))
        #expect(m.shapes.first?.parsedKind == .circle)
    }

    @Test func 文字列のJSONの最後のかっこが抜けていても読める() throws {
        let inner = #"{"type":"chalk_drawing","shapes":[{"kind":"text","text":"a}[","points":[[50,30]]}]"#
        let input = try JSONValue.object(["title": .string("円"), "component": .string(inner)]).jsonData()
        let m = try #require(drawing(BoardTools.content(toolName: BoardTools.showBoardName, input: input)))
        #expect(m.shapes.first?.text == "a}[")
        #expect(BoardTools.closingBrackets(#"{"a":["x"#) == #"{"a":["x"#)
        #expect(BoardTools.closingBrackets(#"{"a":[1,{"b":2}"#) == #"{"a":[1,{"b":2}]}"#)
    }

    @Test func 知らない図形だけなら文字で代わりに出す() {
        let shown = content(#"[{"kind":"hexagon_star","points":[[10,10]],"text":"ほし"}]"#)
        guard case .text(let text) = shown else {
            Issue.record("文字の代わりになっていない: \(shown)")
            return
        }
        #expect(text.contains("ほし"))
        #expect(!text.contains("hexagon_star"))
    }

    @Test func 段階はstepの番号の数で番号は詰めて数える() throws {
        let m = try #require(drawing(content(#"""
        [{"kind":"line","points":[[0,0],[10,0]],"step":0},{"kind":"line","points":[[0,0],[10,0]],"step":5},
         {"kind":"text","text":"a","points":[[5,5]],"step":5},{"kind":"text","text":"b","points":[[5,5]],"step":9}]
        """#)))
        #expect(m.stepCount == 3)
        #expect(m.shapes.map { m.revealIndex(of: $0) } == [0, 1, 1, 2])
        #expect(BoardContent.component(title: "", .chalkDrawing(m)).revealUnits == 3)
    }

    @Test func 答えの文字だけ隠して図形の種類やスタンプの名前は触らない() throws {
        let guardian = AnswerLeakGuard(answer: "24cm²", variants: ["24"])
        let board = content(#"[{"kind":"text","text":"24cm²","points":[[50,30]]},{"kind":"stamp","stamp":"beaker","text":"水","points":[[20,30]],"color":"blue"}]"#)
        let masked = guardian.mask(board)
        #expect(masked.maskedCount == 1)
        let m = try #require(drawing(masked.content))
        #expect(m.shapes[0].text == AnswerLeakGuard.maskText)
        #expect(m.shapes[1].stamp == "beaker" && m.shapes[1].text == "水" && m.shapes[1].color == "blue")
    }

    @Test func スキーマにすべての図形とスタンプの名前が載っている() throws {
        let text = String(decoding: try ShowBoardInput.schema.jsonData(), as: UTF8.self)
        for kind in ChalkDrawing.Kind.allCases { #expect(text.contains(kind.rawValue)) }
        for stamp in ChalkDrawing.Stamp.allCases { #expect(text.contains(stamp.rawValue)) }
    }

    @Test func 座標が黒板の外でも近くに収める() {
        let shape = ChalkDrawing.Shape(kind: .line, points: [[-500, 30], [900, 1e9], [1]])
        #expect(shape.cgPoints == [CGPoint(x: -10, y: 30), CGPoint(x: 110, y: 80)])
    }

    @Test(arguments: ChalkDrawing.Kind.allCases)
    func どの図形も線か文字が出る(_ kind: ChalkDrawing.Kind) {
        let shape = ChalkDrawing.Shape(kind: kind, points: [[20, 20], [60, 20], [40, 50]], radius: 8, text: "あ", stamp: .flask)
        let geometry = ChalkGeometry(shape: shape)
        #expect(!geometry.stroke.isEmpty || !geometry.labels.isEmpty)
    }

    @Test func 点が足りない図形は描かない() {
        #expect(ChalkGeometry(shape: .init(kind: .arrow, points: [[1, 1]])).stroke.isEmpty)
        #expect(ChalkGeometry(shape: .init(kind: .angle, points: [[1, 1], [2, 2]])).stroke.isEmpty)
        #expect(ChalkGeometry(shape: .init(kind: .stamp, points: [[1, 1]], stamp: nil)).stroke.isEmpty)
    }

    @Test(arguments: ChalkDrawing.Stamp.allCases)
    func スタンプは高さ1の箱に収まる(_ stamp: ChalkDrawing.Stamp) {
        let art = ChalkStamps.art(for: stamp)
        guard !art.stroke.isEmpty else {
            // 文字だけのスタンプ（学校の「文」）
            #expect(!art.texts.isEmpty)
            return
        }
        let box = art.stroke.boundingRect
        #expect(box.minY >= -0.1 && box.maxY <= 1.05, "\(stamp): \(box)")
        #expect(box.minX >= -0.65 && box.maxX <= 0.65, "\(stamp): \(box)")
        #expect(box.height > 0.2, "\(stamp): \(box)")
    }

    @Test func サンプルはどれも読める() {
        #expect(drawing(BoardSamples.content(.chalkDrawing)) != nil)
        for sample in BoardSamples.drawingJSON {
            #expect(BoardSamples.drawing(named: sample.name).flatMap(drawing) != nil, "\(sample.name)")
        }
    }

    @Test func 重なる文字はずらして重ならないようにする() {
        let m = ChalkDrawing(shapes: [
            .init(kind: .text, points: [[50, 30]], text: "上と下、先は？"),
            .init(kind: .text, points: [[52, 31]], text: "おがくずの動き"),
            .init(kind: .stamp, points: [[50, 20]], text: "ビーカー", stamp: .beaker),
        ])
        let positions = ChalkLabelLayout.positions(for: m)
        // 最初の文字は動かさない
        #expect(positions[0] == [CGPoint(x: 50, y: 30)])
        var boxes: [CGRect] = []
        for (shape, points) in zip(m.shapes, positions) {
            for (label, point) in zip(ChalkGeometry(shape: shape).labels, points) {
                boxes.append(ChalkLabelLayout.box(text: label.text, at: point, size: label.size).insetBy(dx: 0.4, dy: 0.3))
            }
        }
        for i in boxes.indices {
            for j in boxes.indices where j > i { #expect(!boxes[i].intersects(boxes[j]), "\(i) と \(j)") }
            #expect(boxes[i].minY >= -1 && boxes[i].maxY <= ChalkDrawing.height + 1)
        }
    }

    @Test func 重ならない文字は動かさない() {
        let m = ChalkDrawing(shapes: [
            .init(kind: .text, points: [[20, 10]], text: "A"),
            .init(kind: .text, points: [[80, 60]], text: "B"),
        ])
        #expect(ChalkLabelLayout.positions(for: m) == [[CGPoint(x: 20, y: 10)], [CGPoint(x: 80, y: 60)]])
    }

    @Test func 文字が線にかぶるときは近くの空いている所へずらす() {
        let m = ChalkDrawing(shapes: [
            .init(kind: .line, points: [[10, 30], [90, 30]]),
            .init(kind: .text, points: [[50, 30]], text: "ここ"),
        ])
        let point = ChalkLabelLayout.positions(for: m)[1][0]
        let rect = ChalkLabelLayout.box(text: "ここ", at: point, size: 3.6).insetBy(dx: 0.4, dy: 0.3)
        #expect(!ChalkLabelLayout.samples(of: ChalkGeometry(shape: m.shapes[0]).stroke).contains { rect.contains($0) })
        #expect(abs(point.y - 30) < 6 && point.x == 50)
    }

    @Test func 四角の中のラベルは線にかぶらなければそのまま() {
        let m = ChalkDrawing(shapes: [.init(kind: .rect, points: [[20, 20], [40, 40]], text: "30g")])
        #expect(ChalkLabelLayout.positions(for: m) == [[CGPoint(x: 30, y: 30)]])
    }

    @Test func スタンプの中の文字はずらさない() {
        let m = ChalkDrawing(shapes: [.init(kind: .stamp, points: [[50, 35]], text: "かん電池", stamp: .battery, size: 1.6)])
        let labels = ChalkGeometry(shape: m.shapes[0]).labels
        let positions = ChalkLabelLayout.positions(for: m)[0]
        for (label, point) in zip(labels, positions) where label.isFixed {
            #expect(point == label.at, "\(label.text)")
        }
        #expect(labels.filter(\.isFixed).map(\.text) == ["＋", "－"])
    }
}
