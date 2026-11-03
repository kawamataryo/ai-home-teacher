import SwiftUI

/// 数直線。範囲のかっこは上、点の印は線の上に出す。
struct NumberLineView: View {
    let model: NumberLine
    @Environment(\.boardAnimated) private var animated
    @State private var drawn = false

    var body: some View {
        let scale = NumberLineScale(model)
        Canvas { ctx, size in
            let pad: CGFloat = 70
            let y = size.height * 0.5
            let x = { (v: Double) -> CGFloat in pad + CGFloat(scale.fraction(v)) * (size.width - pad * 2) }

            // 線と矢印
            var line = Path()
            line.move(to: CGPoint(x: pad - 30, y: y))
            line.addLine(to: CGPoint(x: size.width - pad + 40, y: y))
            line.move(to: CGPoint(x: size.width - pad + 26, y: y - 12))
            line.addLine(to: CGPoint(x: size.width - pad + 40, y: y))
            line.addLine(to: CGPoint(x: size.width - pad + 26, y: y + 12))
            ctx.stroke(line, with: .color(Chalk.white), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))

            // 目盛り
            for (i, v) in scale.ticks.enumerated() {
                let major = i % scale.labelEvery == 0
                var t = Path()
                t.move(to: CGPoint(x: x(v), y: y - (major ? 16 : 9)))
                t.addLine(to: CGPoint(x: x(v), y: y + (major ? 16 : 9)))
                ctx.stroke(t, with: .color(Chalk.white), lineWidth: 3)
                if major {
                    ctx.draw(Text(Chalk.number(v) + (i == scale.ticks.count - 1 ? model.unit : ""))
                        .font(Chalk.font(26)).foregroundStyle(Chalk.white),
                             at: CGPoint(x: x(v), y: y + 42))
                }
            }

            // 範囲（かっこ）
            for (i, r) in model.ranges.enumerated() {
                let a = x(scale.clamp(Swift.min(r.from, r.to))), b = x(scale.clamp(Swift.max(r.from, r.to)))
                let top = y - 70 - CGFloat(i % 2) * 60
                var p = Path()
                p.move(to: CGPoint(x: a, y: y - 20))
                p.addQuadCurve(to: CGPoint(x: (a + b) / 2, y: top), control: CGPoint(x: a, y: top))
                p.addQuadCurve(to: CGPoint(x: b, y: y - 20), control: CGPoint(x: b, y: top))
                ctx.stroke(p, with: .color(Chalk.pink), style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                ctx.draw(Text(r.label).font(Chalk.font(28, weight: .bold)).foregroundStyle(Chalk.pink),
                         at: CGPoint(x: (a + b) / 2, y: top - 22))
            }

            // 点の印
            for m in model.marks {
                let p = CGPoint(x: x(scale.clamp(m.value)), y: y)
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 11, y: p.y - 11, width: 22, height: 22)), with: .color(Chalk.yellow))
                ctx.draw(Text(m.label).font(Chalk.font(30, weight: .bold)).foregroundStyle(Chalk.yellow),
                         at: CGPoint(x: p.x, y: y + 90))
            }
        }
        .frame(minHeight: 260)
        .opacity(!animated || drawn ? 1 : 0)
        .scaleEffect(x: !animated || drawn ? 1 : 0.6, y: 1, anchor: .leading)
        .task {
            guard animated else { return }
            withAnimation(.easeOut(duration: 0.6)) { drawn = true }
        }
    }
}

/// 数直線の目盛りの計算。おかしな値（step が 0、min > max など）でも固まらないように丸める。
struct NumberLineScale {
    let lower: Double
    let upper: Double
    let ticks: [Double]
    let labelEvery: Int

    static let maxTicks = 40
    static let maxLabels = 12

    init(_ model: NumberLine) {
        var lo = model.min.isFinite ? model.min : 0
        var hi = model.max.isFinite ? model.max : 1
        if lo > hi { swap(&lo, &hi) }
        // 幅があふれる（±1e308 など）ときは描けないので 0〜1 にする
        if !(hi - lo).isFinite || abs(lo) > 1e12 || abs(hi) > 1e12 { (lo, hi) = (0, 1) }
        if hi - lo < 1e-9 { hi = lo + 1 }
        var step = model.step.isFinite ? abs(model.step) : 0
        if step < 1e-9 || (hi - lo) / step > Double(Self.maxTicks) {
            step = (hi - lo) / 10
        }
        let raw = ((hi - lo) / step).rounded(.down)
        let count = raw.isFinite ? Swift.min(Swift.max(Int(raw), 1), Self.maxTicks) : 10
        lower = lo
        upper = hi
        ticks = (0...count).map { lo + Double($0) * step }
        labelEvery = Swift.max(1, Int((Double(ticks.count) / Double(Self.maxLabels)).rounded(.up)))
    }

    func fraction(_ v: Double) -> Double { (clamp(v) - lower) / (upper - lower) }

    func clamp(_ v: Double) -> Double {
        guard v.isFinite else { return lower }
        return Swift.min(Swift.max(v, lower), upper)
    }
}
