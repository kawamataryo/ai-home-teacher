import SwiftUI

/// ベン図。全体の枠の中に、重なる2つの円を描く。
struct VennDiagramView: View {
    let model: VennDiagram
    @Environment(\.boardAnimated) private var animated
    @State private var shown = false

    var body: some View {
        Canvas { ctx, size in
            let frame = CGRect(x: 8, y: 8, width: size.width - 16, height: size.height - 16)
            // 全体の枠
            ctx.stroke(Path(roundedRect: frame, cornerRadius: 18), with: .color(Chalk.white), lineWidth: 3)
            if !model.universeLabel.isEmpty {
                ctx.draw(text(model.universeLabel, 28, Chalk.white, .bold), at: CGPoint(x: frame.minX + 24, y: frame.minY + 30), anchor: .leading)
            }
            // 2つの円（重なりは半径の 0.55 倍ぶん）
            let r = Swift.min(frame.width * 0.24, frame.height * 0.36)
            let cy = frame.midY + 20
            let gap = r * 0.55
            let left = CGPoint(x: frame.midX - r + gap / 2, y: cy)
            let right = CGPoint(x: frame.midX + r - gap / 2, y: cy)
            for (center, color) in [(left, Chalk.blue), (right, Chalk.pink)] {
                let circle = Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
                ctx.fill(circle, with: .color(color.opacity(0.16)))
                ctx.stroke(circle, with: .color(color), lineWidth: 4)
            }
            // 円の名前は上に、中身は部分ごとに
            ctx.draw(text(model.leftLabel, 30, Chalk.blue, .heavy), at: CGPoint(x: left.x - r * 0.35, y: cy - r - 26))
            ctx.draw(text(model.rightLabel, 30, Chalk.pink, .heavy), at: CGPoint(x: right.x + r * 0.35, y: cy - r - 26))
            let overlapX = (left.x + r + right.x - r) / 2
            ctx.draw(text(model.leftOnly, 26, Chalk.white), at: CGPoint(x: (left.x - r + right.x - r) / 2, y: cy))
            ctx.draw(text(model.rightOnly, 26, Chalk.white), at: CGPoint(x: (left.x + r + right.x + r) / 2, y: cy))
            ctx.draw(text(model.both, 26, Chalk.yellow, .bold), at: CGPoint(x: overlapX, y: cy))
            if !model.neither.isEmpty {
                ctx.draw(text(model.neither, 26, Chalk.white), at: CGPoint(x: frame.maxX - 24, y: frame.maxY - 30), anchor: .trailing)
            }
        }
        .frame(minHeight: 380)
        .opacity(!animated || shown ? 1 : 0)
        .scaleEffect(!animated || shown ? 1 : 0.9)
        .task {
            guard animated else { return }
            withAnimation(.spring(duration: 0.7)) { shown = true }
        }
    }

    private func text(_ s: String, _ size: CGFloat, _ color: Color, _ weight: Font.Weight = .semibold) -> Text {
        Text(s).font(Chalk.font(size, weight: weight)).foregroundStyle(color)
    }
}
