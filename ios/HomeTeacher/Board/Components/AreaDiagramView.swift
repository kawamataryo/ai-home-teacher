import SwiftUI

/// 面積図。長方形を下そろえで左から並べる。
struct AreaDiagramView: View {
    let model: AreaDiagram
    @Environment(\.boardAnimated) private var animated
    @State private var grown = false

    private static let fills = [Chalk.blue, Chalk.pink, Chalk.yellow, Chalk.white]

    var body: some View {
        let parts = model.parts
        let widths = DiagramScale.normalized(parts.map(\.width))
        let heights = DiagramScale.relativeToMax(parts.map(\.height)).map { Swift.max($0, 0.08) }
        Canvas { ctx, size in
            let left: CGFloat = 40, right: CGFloat = 40, top: CGFloat = 60
            let bottom: CGFloat = model.totalLabel.isEmpty ? 70 : 140
            let areaW = size.width - left - right
            let areaH = size.height - top - bottom
            let baseY = top + areaH
            var x = left
            for (i, part) in parts.enumerated() {
                let w = areaW * widths[i]
                let h = areaH * heights[i]
                let rect = CGRect(x: x, y: baseY - h, width: w, height: h)
                let color = Self.fills[i % Self.fills.count]
                ctx.fill(Path(rect), with: .color(color.opacity(0.22)))
                ctx.stroke(Path(rect), with: .color(Chalk.white), lineWidth: 3)
                ctx.draw(Text(part.label).font(Chalk.font(28, weight: .bold)).foregroundStyle(color),
                         at: CGPoint(x: rect.midX, y: rect.midY))
                ctx.draw(Text(part.widthLabel).font(Chalk.font(26)).foregroundStyle(Chalk.white),
                         at: CGPoint(x: rect.midX, y: baseY + 30))
                ctx.draw(Text("↕\u{FE0E} " + part.heightLabel).font(Chalk.font(26)).foregroundStyle(Chalk.blue),
                         at: CGPoint(x: rect.minX + 8, y: rect.minY - 26), anchor: .leading)
                x += w
            }
            if !model.totalLabel.isEmpty {
                // 全体を示すかっこ
                let y = baseY + 66
                var brace = Path()
                brace.move(to: CGPoint(x: left, y: y - 12))
                brace.addLine(to: CGPoint(x: left, y: y))
                brace.addLine(to: CGPoint(x: left + areaW, y: y))
                brace.addLine(to: CGPoint(x: left + areaW, y: y - 12))
                ctx.stroke(brace, with: .color(Chalk.yellow), lineWidth: 3)
                ctx.draw(Text(model.totalLabel).font(Chalk.font(28, weight: .bold)).foregroundStyle(Chalk.yellow),
                         at: CGPoint(x: left + areaW / 2, y: y + 32))
            }
        }
        .frame(minHeight: 320)
        .scaleEffect(y: !animated || grown ? 1 : 0.02, anchor: .bottom)
        .task {
            guard animated else { return }
            withAnimation(.spring(duration: 0.8)) { grown = true }
        }
    }
}

/// 図の比率の正規化。0 や負の値、NaN があっても描けるようにする。
enum DiagramScale {
    /// 合計が 1 になる比率（よこ方向）。
    static func normalized(_ values: [Double]) -> [CGFloat] {
        let safe = values.map { $0.isFinite && $0 > 0 ? $0 : 0 }
        let total = safe.reduce(0, +)
        guard total > 0 else { return values.map { _ in values.isEmpty ? 0 : 1 / CGFloat(values.count) } }
        // 小さすぎて見えない区切りは、最低でも全体の 4% にする
        let floored = safe.map { Swift.max($0 / total, 0.04) }
        let sum = floored.reduce(0, +)
        return floored.map { CGFloat($0 / sum) }
    }

    /// 最大値を 1 とした比率（たて方向）。
    static func relativeToMax(_ values: [Double]) -> [CGFloat] {
        let safe = values.map { $0.isFinite && $0 > 0 ? $0 : 0 }
        guard let m = safe.max(), m > 0 else { return values.map { _ in 0 } }
        return safe.map { CGFloat($0 / m) }
    }
}
