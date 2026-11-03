import SwiftUI

/// 表。行の長さがそろっていなくても、足りないマスは空欄で埋める。
struct BoardTableView: View {
    let model: BoardTable
    @Environment(\.boardAnimated) private var animated
    @State private var shown = false

    var body: some View {
        let grid = TableGrid(model)
        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(0..<grid.columns, id: \.self) { c in
                    cell(grid.header(c), color: Chalk.yellow, bold: true, highlighted: false)
                }
            }
            ForEach(0..<grid.rows.count, id: \.self) { r in
                GridRow {
                    ForEach(0..<grid.columns, id: \.self) { c in
                        cell(grid.rows[r][c], color: Chalk.white, bold: c == 0, highlighted: grid.isHighlighted(row: r, column: c))
                    }
                }
            }
        }
        .overlay(Rectangle().strokeBorder(Chalk.white, lineWidth: 3))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(!animated || shown ? 1 : 0)
        .task {
            guard animated else { return }
            withAnimation(.easeOut(duration: 0.5)) { shown = true }
        }
    }

    private func cell(_ text: String, color: Color, bold: Bool, highlighted: Bool) -> some View {
        Text(text)
            .font(Chalk.font(28, weight: bold ? .bold : .medium))
            .foregroundStyle(highlighted ? Chalk.boardDeep : color)
            .lineLimit(2)
            .minimumScaleFactor(0.5)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 72)
            .background(highlighted ? Chalk.pink : Color.clear)
            .overlay(Rectangle().strokeBorder(Chalk.faint, lineWidth: 1.5))
    }
}

/// 表のマスの整理。ずれた行・範囲外の強調でも落ちない。
struct TableGrid {
    let headers: [String]
    let rows: [[String]]
    let columns: Int
    private let highlights: Set<[Int]>

    init(_ model: BoardTable) {
        let width = ([model.headers.count] + model.rows.map(\.count)).max() ?? 0
        columns = width
        headers = model.headers
        rows = model.rows.map { $0 + Array(repeating: "", count: width - $0.count) }
        highlights = Set(model.highlightCells.map { [$0.row, $0.column] })
    }

    func header(_ c: Int) -> String { headers.indices.contains(c) ? headers[c] : "" }

    func isHighlighted(row: Int, column: Int) -> Bool { highlights.contains([row, column]) }
}
