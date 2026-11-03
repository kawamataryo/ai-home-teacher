import SwiftUI

/// 先生の黒板。中身（BoardContent）に合わせて部品・文字を出し分ける。
struct BoardView: View {
    let content: BoardContent

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let title, !title.isEmpty {
                Text(title)
                    .font(Chalk.font(36, weight: .bold))
                    .foregroundStyle(Chalk.yellow)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
            }
            body(for: content)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(LinearGradient(colors: [Chalk.board, Chalk.boardDeep], startPoint: .top, endPoint: .bottom))
        )
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Chalk.frame, lineWidth: 14))
        .foregroundStyle(Chalk.white)
        .id(content)
        .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.96)), removal: .opacity))
    }

    private var title: String? {
        if case .component(let title, _) = content { return title }
        return nil
    }

    @ViewBuilder
    private func body(for content: BoardContent) -> some View {
        switch content {
        case .component(_, let component):
            switch component {
            case .stepCards(let m): StepCardsView(model: m)
            case .numberLine(let m): NumberLineView(model: m)
            case .areaDiagram(let m): AreaDiagramView(model: m)
            case .segmentDiagram(let m): SegmentDiagramView(model: m)
            case .table(let m): BoardTableView(model: m)
            case .barChart(let m): BarChartView(model: m)
            case .highlightImage(let m): HighlightImageView(model: m)
            case .essayOutline(let m): EssayOutlineView(model: m)
            case .vennDiagram(let m): VennDiagramView(model: m)
            case .timeline(let m): BoardTimelineView(model: m)
            case .percentBar(let m): PercentBarView(model: m)
            }
        case .svg(let board):
            SVGBoardView(board: board)
        case .text(let text):
            BoardTextView(text: text)
        }
    }
}

/// 図を出せなかったときの文字の黒板。
struct BoardTextView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Chalk.font(30, weight: .medium))
            .lineSpacing(10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

extension BoardContent: Hashable {
    func hash(into hasher: inout Hasher) {
        switch self {
        case .component(let title, let c):
            hasher.combine(title)
            hasher.combine(c.kind.rawValue)
        case .svg(let b):
            hasher.combine(b.svg)
        case .text(let t):
            hasher.combine(t)
        }
    }
}

#Preview("手順カード") {
    BoardView(content: BoardSamples.content(.stepCards)).frame(width: 1000, height: 700)
}

#Preview("文字の代替表示") {
    BoardView(content: BoardTools.content(toolName: "show_board", input: Data(BoardSamples.brokenJSON.utf8)))
        .frame(width: 1000, height: 500)
}
