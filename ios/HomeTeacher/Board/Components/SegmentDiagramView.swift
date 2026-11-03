import SwiftUI

/// 線分図。テープを上から並べ、長さは全テープ共通の比率で描く。
struct SegmentDiagramView: View {
    let model: SegmentDiagram
    @Environment(\.boardAnimated) private var animated
    @State private var drawn = false

    private static let colors = [Chalk.blue, Chalk.pink, Chalk.yellow]

    var body: some View {
        let lengths = model.bars.map { $0.segments.map { $0.length.isFinite && $0.length > 0 ? $0.length : 0 } }
        let longest = lengths.map { $0.reduce(0, +) }.max() ?? 0
        let unit = longest > 0 ? longest : 1
        Canvas { ctx, size in
            let nameW: CGFloat = 130, right: CGFloat = 170
            let tapeW = size.width - nameW - right
            let rowH = Swift.min(170, size.height / CGFloat(Swift.max(model.bars.count, 1)))
            for (row, bar) in model.bars.enumerated() {
                let y = rowH * CGFloat(row) + rowH * 0.6
                ctx.draw(Text(bar.name).font(Chalk.font(30, weight: .bold)).foregroundStyle(Chalk.white),
                         at: CGPoint(x: nameW - 20, y: y), anchor: .trailing)
                var x = nameW
                for (i, seg) in bar.segments.enumerated() {
                    // 0 の区切りも見えるよう、最低の幅を持たせる
                    let w = Swift.max(tapeW * CGFloat(lengths[row][i] / unit), 24)
                    let rect = CGRect(x: x, y: y - 22, width: w, height: 44)
                    let color = Self.colors[i % Self.colors.count]
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(color.opacity(0.25)))
                    ctx.stroke(Path(roundedRect: rect, cornerRadius: 4), with: .color(Chalk.white), lineWidth: 3)
                    ctx.draw(Text(seg.label).font(Chalk.font(24, weight: .semibold)).foregroundStyle(color),
                             at: CGPoint(x: rect.midX, y: y - 46))
                    x += w
                }
                if !bar.totalLabel.isEmpty {
                    ctx.draw(Text("} " + bar.totalLabel).font(Chalk.font(28, weight: .bold)).foregroundStyle(Chalk.yellow),
                             at: CGPoint(x: x + 14, y: y), anchor: .leading)
                }
            }
            // テープの左端をそろえる線
            var guide = Path()
            guide.move(to: CGPoint(x: nameW, y: 10))
            guide.addLine(to: CGPoint(x: nameW, y: rowH * CGFloat(model.bars.count)))
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
