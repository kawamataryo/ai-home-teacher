import SwiftUI

/// 線分図。テープを上から並べ、長さは全テープ共通の比率で描く。
/// 段階表示（`boardRevealCount`）のときは、見せたテープだけを描き、いま話しているテープ（`boardFocusIndex`）を目立たせる。
struct SegmentDiagramView: View {
    let model: SegmentDiagram
    @Environment(\.boardAnimated) private var animated
    @Environment(\.boardRevealCount) private var revealCount
    @Environment(\.boardFocusIndex) private var focusIndex
    @State private var drawn = false

    private static let colors = [Chalk.blue, Chalk.pink, Chalk.yellow]
    private static let nameFont = Chalk.font(30, weight: .bold)
    private static let totalFont = Chalk.font(28, weight: .bold)

    var body: some View {
        let lengths = model.bars.map { $0.segments.map { $0.length.isFinite && $0.length > 0 ? $0.length : 0 } }
        let longest = lengths.map { $0.reduce(0, +) }.max() ?? 0
        let unit = longest > 0 ? longest : 1
        Canvas { ctx, size in
            // 名前と合計の文字の幅に合わせて、テープの左右をあける（はみ出さないように）
            let names = model.bars.map { ctx.resolve(Text($0.name).font(Self.nameFont).foregroundStyle(Chalk.white)) }
            let totals = model.bars.map { ctx.resolve(Text("} " + $0.totalLabel).font(Self.totalFont).foregroundStyle(Chalk.yellow)) }
            let nameW = Swift.min(size.width * 0.3, (names.map { $0.measure(in: size).width }.max() ?? 0) + 28)
            let hasTotal = model.bars.contains { !$0.totalLabel.isEmpty }
            let right = hasTotal ? Swift.min(size.width * 0.3, (totals.map { $0.measure(in: size).width }.max() ?? 0) + 24) : 16
            let tapeW = Swift.max(size.width - nameW - right, 40)
            let rowH = Swift.min(170, size.height / CGFloat(Swift.max(model.bars.count, 1)))
            // 図が上に寄らないよう、全体を縦の真ん中に置く
            let top = Swift.max(0, (size.height - rowH * CGFloat(model.bars.count)) / 2)
            for (row, bar) in model.bars.enumerated() where row < revealCount {
                let y = top + rowH * CGFloat(row) + rowH * 0.6
                let focused = row == focusIndex
                ctx.draw(names[row], at: CGPoint(x: nameW - 16, y: y), anchor: .trailing)
                var x = nameW
                for (i, seg) in bar.segments.enumerated() {
                    // 0 の区切りも見えるよう、最低の幅を持たせる
                    let w = Swift.max(tapeW * CGFloat(lengths[row][i] / unit), 24)
                    let rect = CGRect(x: x, y: y - 22, width: w, height: 44)
                    let color = Self.colors[i % Self.colors.count]
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(color.opacity(focused ? 0.4 : 0.25)))
                    ctx.stroke(Path(roundedRect: rect, cornerRadius: 4), with: .color(Chalk.white), lineWidth: 3)
                    let label = ctx.resolve(Text(seg.label).font(Chalk.font(24, weight: .semibold)).foregroundStyle(color))
                    ctx.draw(label, at: CGPoint(x: rect.midX, y: y - 46))
                    x += w
                }
                if focused {
                    let whole = CGRect(x: nameW - 6, y: y - 30, width: x - nameW + 12, height: 60)
                    ctx.stroke(Path(roundedRect: whole, cornerRadius: 8), with: .color(Chalk.yellow), lineWidth: 3)
                }
                if !bar.totalLabel.isEmpty {
                    ctx.draw(totals[row], at: CGPoint(x: x + 12, y: y), anchor: .leading)
                }
            }
            // テープの左端をそろえる線
            var guide = Path()
            guide.move(to: CGPoint(x: nameW, y: top + 10))
            guide.addLine(to: CGPoint(x: nameW, y: top + rowH * CGFloat(model.bars.count)))
            ctx.stroke(guide, with: .color(Chalk.faint), style: StrokeStyle(lineWidth: 2, dash: [6, 6]))
        }
        .frame(minHeight: 260)
        .mask(alignment: .leading) {
            GeometryReader { geo in
                Rectangle().frame(width: !animated || drawn ? geo.size.width : 0)
            }
        }
        .task {
            guard animated else { return }
            withAnimation(.easeInOut(duration: 0.9)) { drawn = true }
        }
    }
}
