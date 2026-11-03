import Foundation
import SwiftUI
import Testing
@testable import HomeTeacher

struct BoardRevealTests {
    private static let cards = BoardContent.component(title: "考える順番", .stepCards(.init(steps: [
        .init(heading: "何を聞かれている？", detail: "a"),
        .init(heading: "どこを見る？", detail: "b"),
        .init(heading: "ということは？", detail: "c"),
    ])))

    @Test func 手順カードは1枚ずつ見せていちばん新しいカードを強調する() {
        var reveal = BoardReveal(content: Self.cards, pace: .sentence)
        #expect(reveal.total == 3)
        #expect(reveal.shown == 1)
        #expect(reveal.focus == 0)
        reveal.advance()
        #expect(reveal.shown == 2)
        #expect(reveal.focus == 1)
        reveal.advance(by: 5)
        #expect(reveal.shown == 3)
        #expect(reveal.isComplete)
        // 全部見せたら強調しない
        #expect(reveal.focus == nil)
    }

    @Test func 資料の部品は最初から全部見せる() {
        let table = BoardContent.component(title: "", .table(.init(headers: ["月"], rows: [["4月"], ["5月"]], highlightCells: [])))
        let reveal = BoardReveal(content: table, pace: .hintStage)
        #expect(reveal.isComplete)
        #expect(reveal.focus == nil)
        #expect(BoardReveal(content: .text("x"), pace: .sentence).isComplete)
    }

    @Test func 空の部品や大きすぎる初期値でも範囲に収まる() {
        let empty = BoardContent.component(title: "", .stepCards(.init(steps: [])))
        #expect(BoardReveal(content: empty, pace: .sentence).shown == 1)
        #expect(BoardReveal(content: Self.cards, pace: .sentence, initiallyShown: 99).shown == 3)
        var reveal = BoardReveal(content: Self.cards, pace: .sentence, initiallyShown: -3)
        #expect(reveal.shown == 1)
        reveal.advance(by: -2)
        #expect(reveal.shown == 1)
        reveal.revealAll()
        #expect(reveal.isComplete)
    }

    /// 段階表示の途中（2枚目まで）でも描ける。
    @MainActor @Test func 途中まで見せた黒板を描ける() {
        var reveal = BoardReveal(content: Self.cards, pace: .sentence)
        reveal.advance()
        let view = BoardView(content: Self.cards)
            .frame(width: 1100, height: 860)
            .environment(\.boardAnimated, false)
            .boardReveal(reveal)
        #expect(ImageRenderer(content: view).uiImage != nil)
    }

    /// `TEST_RUNNER_BOARD_SNAPSHOT=1` のときだけ、段階表示のスクリーンショットを docs/screenshots/boards-eval/reveal-*.png に書き出す。
    @MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["BOARD_SNAPSHOT"] == "1"))
    func 段階表示のスクリーンショットを書き出す() throws {
        let ratio = BoardContent.component(title: "割合の考える順番", .stepCards(.init(steps: [
            .init(heading: "もとにする量はどれ？", detail: "「〇〇の25%」の〇〇を探そう"),
            .init(heading: "割合を小数にすると？", detail: "25% は 100 のうちの 25"),
            .init(heading: "安くなるのはいくら？", detail: "もとにする量 × 割合"),
            .init(heading: "ということは？", detail: "はらうのはいくらかな？"),
        ])))
        let dir = BoardEvalTests.repoRoot.appending(path: "docs/screenshots/boards-eval")
        var reveal = BoardReveal(content: ratio, pace: .sentence)
        for step in 1...3 {
            let view = BoardView(content: ratio)
                .frame(width: 1100, height: 860)
                .environment(\.boardAnimated, false)
                .environment(\.colorScheme, .dark)
                .boardReveal(reveal)
            let image = try #require(ImageRenderer(content: view).uiImage)
            try #require(image.pngData()).write(to: dir.appending(path: "reveal-\(step).png"))
            reveal.advance()
        }
    }
}

struct BoardLeakMaskTests {
    private let guardian = AnswerLeakGuard(answer: "24cm²", variants: ["24"])

    @Test func 答えを含む文字だけをはてなにして図は残す() {
        let content = BoardContent.component(title: "面積の求め方", .stepCards(.init(steps: [
            .init(heading: "たてとよこ", detail: "4cm と 6cm"),
            .init(heading: "かけ算", detail: "4×6＝24cm²"),
        ])))
        let masked = guardian.mask(content)
        #expect(masked.maskedCount == 1)
        guard case .component("面積の求め方", .stepCards(let cards)) = masked.content else {
            Issue.record("部品でなくなった: \(masked.content)")
            return
        }
        #expect(cards.steps.map(\.detail) == ["4cm と 6cm", "？"])
    }

    @Test func 答えがなければそのまま() {
        let content = BoardContent.component(title: "t", .barChart(.init(unit: "冊", bars: [.init(label: "4月", value: 120, highlighted: false)])))
        #expect(guardian.mask(content) == .init(content: content, maskedCount: 0))
        // 作文（正答なし）は何もしない
        #expect(AnswerLeakGuard(answer: "").mask(.text("24cm²")).maskedCount == 0)
    }

    @Test func 子どもが先に答えを言ったあとは消さない() {
        var g = guardian
        g.noteChildUtterance("24cm²だ！")
        #expect(g.mask(.text("答えは 24cm²")).maskedCount == 0)
    }

    @Test func SVGは文字だけを照合しstyleの中は触らない() {
        let svg = #"<svg viewBox="0 0 10 10"><style>.a{font-size:24px}</style><text class="a">24cm²</text><text>たて4cm</text></svg>"#
        let masked = guardian.mask(.svg(SVGBoard(svg: svg, caption: "答えは24cm²")))
        guard case .svg(let board) = masked.content else {
            Issue.record("SVG でなくなった")
            return
        }
        #expect(board.svg == #"<svg viewBox="0 0 10 10"><style>.a{font-size:24px}</style><text class="a">？</text><text>たて4cm</text></svg>"#)
        #expect(board.caption == "？")
        #expect(masked.maskedCount == 2)
    }
}
