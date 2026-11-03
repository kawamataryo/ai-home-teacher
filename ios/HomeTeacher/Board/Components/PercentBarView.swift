import SwiftUI

/// 割合の帯図。もとにする量を 100% の帯にし、割合で区切る。帯の上に量、下に % の目盛り。
struct PercentBarView: View {
    let model: PercentBar
    @Environment(\.boardAnimated) private var animated
    @State private var drawn = false

    private static let colors = [Chalk.blue, Chalk.pink, Chalk.yellow, Chalk.white]

    var body: some View {
        let ratios = PercentBarScale.widths(model.parts.map(\.percent))
        Canvas { ctx, size in
            let left: CGFloat = 30, right: CGFloat = 30
            let width = size.width - left - right
            let barH: CGFloat = 90
            let y = size.height / 2 - barH / 2
            // 帯全体（100%）を示すかっこ
            var brace = Path()
            brace.move(to: CGPoint(x: left, y: y - 70))
            brace.addLine(to: CGPoint(x: left, y: y - 82))
            brace.addLine(to: CGPoint(x: left + width, y: y - 82))
            brace.addLine(to: CGPoint(x: left + width, y: y - 70))
            ctx.stroke(brace, with: .color(Chalk.yellow), lineWidth: 3)
            ctx.draw(Text(model.baseLabel + "（100%）").font(Chalk.font(28, weight: .bold)).foregroundStyle(Chalk.yellow),
                     at: CGPoint(x: left + width / 2, y: y - 110))
            var x = left
            var cumulative = 0.0
            tick(&ctx, x: x, y: y + barH, label: "0%")
            for (i, part) in model.parts.enumerated() {
                let w = width * ratios[i]
                let rect = CGRect(x: x, y: y, width: w, height: barH)
                let color = Self.colors[i % Self.colors.count]
                ctx.fill(Path(rect), with: .color(color.opacity(0.28)))
                ctx.stroke(Path(rect), with: .color(Chalk.white), lineWidth: 3)
                ctx.draw(Text(part.label).font(Chalk.font(26, weight: .bold)).foregroundStyle(Chalk.white),
                         at: CGPoint(x: rect.midX, y: rect.midY))
                if !part.amount.isEmpty {
                    ctx.draw(Text(part.amount).font(Chalk.font(26, weight: .bold)).foregroundStyle(color),
                             at: CGPoint(x: rect.midX, y: y - 30))
                }
                x += w
                cumulative += part.percent.isFinite ? Swift.max(part.percent, 0) : 0
                tick(&ctx, x: x, y: y + barH, label: "\(Chalk.number(cumulative))%")
            }
        }
        .frame(minHeight: 360)
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

    private func tick(_ ctx: inout GraphicsContext, x: CGFloat, y: CGFloat, label: String) {
        var line = Path()
        line.move(to: CGPoint(x: x, y: y))
        line.addLine(to: CGPoint(x: x, y: y + 18))
        ctx.stroke(line, with: .color(Chalk.blue), lineWidth: 3)
        ctx.draw(Text(label).font(Chalk.font(24, weight: .semibold)).foregroundStyle(Chalk.blue), at: CGPoint(x: x, y: y + 40))
    }
}

/// 帯の区切りの幅。合計が 100 を超えたら合計を 1 にし、100 に足りなければ残りは空ける。
enum PercentBarScale {
    static func widths(_ percents: [Double]) -> [CGFloat] {
        let safe = percents.map { $0.isFinite && $0 > 0 ? $0 : 0 }
        let total = Swift.max(safe.reduce(0, +), 100)
        return safe.map { CGFloat($0 / total) }
    }
}
