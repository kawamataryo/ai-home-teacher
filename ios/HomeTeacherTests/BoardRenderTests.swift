import Foundation
import SwiftUI
import Testing
@testable import HomeTeacher

@MainActor
struct BoardRenderTests {
    @Test func 数直線はおかしな値でも目盛りが増えすぎない() {
        let cases: [(Double, Double, Double)] = [(0, 1, 0), (5, 1, 1), (0, 1_000_000, 0.001), (3, 3, 1), (0, .nan, -1)]
        for (lo, hi, step) in cases {
            let s = NumberLineScale(NumberLine(min: lo, max: hi, step: step, unit: "", marks: [], ranges: []))
            #expect(s.lower < s.upper)
            #expect(s.ticks.count >= 2 && s.ticks.count <= NumberLineScale.maxTicks + 1)
            #expect(s.fraction(.infinity) >= 0 && s.fraction(.infinity) <= 1)
        }
    }

    @Test func 表は行の長さがずれても範囲外の強調でも落ちない() {
        let grid = TableGrid(BoardTable(headers: ["a"], rows: [["1", "2", "3"], []],
                                        highlightCells: [.init(row: 99, column: -1), .init(row: 0, column: 2)]))
        #expect(grid.columns == 3)
        #expect(grid.rows.allSatisfy { $0.count == 3 })
        #expect(grid.header(2) == "")
        #expect(grid.isHighlighted(row: 0, column: 2))
    }

    @Test func 比率は0や負やNaNでも描ける() {
        #expect(DiagramScale.normalized([0, 0]) == [0.5, 0.5])
        #expect(DiagramScale.normalized([]) == [])
        let n = DiagramScale.normalized([-1, .nan, 3])
        #expect(abs(n.reduce(0, +) - 1) < 1e-9)
        #expect(n.allSatisfy { $0 > 0 })
        #expect(DiagramScale.relativeToMax([0, -5]) == [0, 0])
        #expect(DiagramScale.relativeToMax([50, 100]) == [0.5, 1])
    }

    @Test func 写真の囲みははみ出しても写真の中に収まる() {
        let frame = CGRect(x: 10, y: 20, width: 200, height: 100)
        let r = HighlightImageView.regionRect(.init(x: 0.9, y: -1, width: 5, height: .nan, label: ""), in: frame)
        #expect(frame.insetBy(dx: -0.001, dy: -0.001).contains(r))
    }

    /// 極端な値の部品を実際に描いて、落ちないことを確かめる。
    @Test func 極端な値の部品を描いても落ちない() throws {
        let hostile: [BoardContent] = [
            .component(title: "", .stepCards(.init(steps: []))),
            .component(title: "", .numberLine(.init(min: 10, max: 10, step: 0, unit: "m",
                                                    marks: [.init(value: .infinity, label: "x")],
                                                    ranges: [.init(from: 99, to: -99, label: "r")]))),
            .component(title: "", .areaDiagram(.init(parts: [.init(width: 0, height: -3, label: "", widthLabel: "", heightLabel: "")], totalLabel: ""))),
            .component(title: "", .areaDiagram(.init(parts: [], totalLabel: "x"))),
            .component(title: "", .segmentDiagram(.init(bars: [.init(name: "a", segments: [.init(length: -1, label: "")], totalLabel: "")]))),
            .component(title: "", .segmentDiagram(.init(bars: []))),
            .component(title: "", .table(.init(headers: [], rows: [], highlightCells: [.init(row: 5, column: 5)]))),
            .component(title: "", .barChart(.init(unit: "", bars: [.init(label: "a", value: 0, highlighted: false), .init(label: "b", value: -10, highlighted: true)]))),
            .component(title: "", .barChart(.init(unit: "", bars: []))),
            .component(title: "", .highlightImage(.init(imageId: "missing", regions: [.init(x: 2, y: 2, width: 2, height: 2, label: "x")]))),
            .component(title: "", .highlightImage(.init(imageId: BoardSamples.photoID, regions: [.init(x: -1, y: 0.5, width: 9, height: 9, label: "x")]))),
            .component(title: "", .essayOutline(.init(theme: "", sections: []))),
            .text(""),
        ]
        for content in hostile {
            #expect(BoardSnapshot.render(content) != nil)
        }
    }

    /// `TEST_RUNNER_BOARD_SNAPSHOT=1 xcodebuild test ...` のときだけ docs/screenshots に PNG を書き出す。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BOARD_SNAPSHOT"] == "1"))
    func スクリーンショットを書き出す() throws {
        let dir = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "docs/screenshots")
        for entry in BoardGallery.entries {
            let name = entry.name.hasPrefix("fallback") ? "fallback" : entry.name.replacingOccurrences(of: "_", with: "-")
            let image = try #require(BoardSnapshot.render(entry.content))
            try #require(image.pngData()).write(to: dir.appending(path: "board-\(name).png"))
        }
    }
}

@MainActor
enum BoardSnapshot {
    static func render(_ content: BoardContent, size: CGSize = CGSize(width: 1100, height: 720)) -> UIImage? {
        let view = BoardView(content: content)
            .frame(width: size.width, height: size.height)
            .environment(\.boardAnimated, false)
            .environment(\.boardImageProvider, BoardImageProvider { BoardSamples.image(for: $0) })
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return renderer.uiImage
    }
}
