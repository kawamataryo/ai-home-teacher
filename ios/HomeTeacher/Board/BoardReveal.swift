import SwiftUI

/// 黒板を段階的に見せる（#70）。部品の「単位」（手順カードの1枚、テープ1本、表の1行など）を1つずつ出す。
///
/// - 写真の分析で出した図：ヒントの段階が進むたびに1つ増やす（答えの手前まで一度に見せない）
/// - 会話の途中で出した図：先生が文を1つ話し始めるたびに1つ増やし、返事が終わったら全部見せる
///
/// 見せている数は `BoardContent` の外に持つ（`BoardView` は中身が変わったときだけ作り直すため）。
struct BoardReveal: Equatable, Sendable {
    enum Pace: Equatable, Sendable {
        /// ヒントの段階に合わせる
        case hintStage
        /// 話している文に合わせる
        case sentence
    }

    let total: Int
    let pace: Pace
    private(set) var shown: Int

    init(content: BoardContent, pace: Pace, initiallyShown: Int = 1) {
        total = Swift.max(content.revealUnits, 1)
        self.pace = pace
        shown = Swift.min(Swift.max(initiallyShown, 1), total)
    }

    var isComplete: Bool { shown >= total }

    /// いちばん新しく出した単位（強調する）。全部出したら nil
    var focus: Int? { isComplete || total <= 1 ? nil : shown - 1 }

    mutating func advance(by count: Int = 1) {
        shown = Swift.min(total, shown + Swift.max(count, 0))
    }

    mutating func revealAll() {
        shown = total
    }
}

extension BoardContent {
    /// 段階的に見せる単位の数。1 なら一度に全部見せる。
    /// 順番に話す部品（手順・量を1本ずつ並べる線分図）だけを分ける。表・グラフ・構成メモは資料なので、最初から全部見せる
    var revealUnits: Int {
        guard case .component(_, let component) = self else { return 1 }
        switch component {
        case .stepCards(let m): return m.steps.count
        case .segmentDiagram(let m): return m.bars.count
        case .table, .barChart, .essayOutline, .areaDiagram, .numberLine, .highlightImage: return 1
        }
    }
}

extension EnvironmentValues {
    /// 見せる単位の数。既定は全部（ギャラリー・スクリーンショット）
    @Entry var boardRevealCount: Int = .max
    /// 強調する単位（いま話している段階）
    @Entry var boardFocusIndex: Int? = nil
}

extension View {
    /// 段階表示の状態を黒板に渡す。
    func boardReveal(_ reveal: BoardReveal?) -> some View {
        environment(\.boardRevealCount, reveal?.shown ?? .max)
            .environment(\.boardFocusIndex, reveal?.focus)
    }
}
