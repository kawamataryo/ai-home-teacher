import SwiftUI

/// 先生の黒板。中身（BoardContent）に合わせて部品・文字を出し分ける。
///
/// 黒板（`BoardSurface`）の上に中身（`BoardContentView`）を置く。セッション画面は中身だけを縮めて、枠は実際の大きさで描く
struct BoardView: View {
    let content: BoardContent

    var body: some View {
        BoardSurface {
            BoardContentView(content: content)
        }
        .animation(.spring(duration: 0.45), value: content)
    }
}

/// 黒板に書く中身（タイトルと部品）。中身が替わると、前の図を拭き取ってから書き直す
struct BoardContentView: View {
    let content: BoardContent
    /// 先生が重なるところの余白（設計の座標）
    var insets = EdgeInsets()
    /// 先生だけのときの小さな看板（使い方の案内を真ん中に大きく書く）
    var isSign = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if let title, !title.isEmpty {
                Text(title)
                    .font(Chalk.font(36, weight: .bold))
                    .foregroundStyle(Chalk.yellow)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .chalkWriteIn(characters: title.count)
            }
            if isSign, case .text(let text) = content {
                Text(text)
                    .font(Chalk.font(34, weight: .bold))
                    .multilineTextAlignment(.center)
                    .lineSpacing(8)
                    .minimumScaleFactor(0.6)
                    .chalkWriteIn(characters: text.count)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                body(for: content)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(18)
        .padding(insets)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .id(content)
        .transition(.boardRewrite)
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
            case .chalkDrawing(let m): ChalkDrawingView(model: m)
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
