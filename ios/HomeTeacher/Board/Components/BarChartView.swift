import SwiftUI

/// 棒グラフ。棒が下からのびる。強調した棒は黄色。
struct BarChartView: View {
    let model: BarChart
    @Environment(\.boardAnimated) private var animated
    @State private var grown = false

    var body: some View {
        let ratios = DiagramScale.relativeToMax(model.bars.map(\.value))
        VStack(alignment: .leading, spacing: 8) {
            Text("（\(model.unit)）")
                .font(Chalk.font(24))
                .foregroundStyle(Chalk.blue)
            GeometryReader { geo in
                let chartH = geo.size.height - 50
                HStack(alignment: .bottom, spacing: 24) {
                    ForEach(Array(model.bars.enumerated()), id: \.offset) { i, bar in
                        VStack(spacing: 8) {
                            Spacer(minLength: 0)
                            Text(Chalk.number(bar.value))
                                .font(Chalk.font(24, weight: .bold))
                                .foregroundStyle(bar.highlighted ? Chalk.yellow : Chalk.white)
                                .opacity(!animated || grown ? 1 : 0)
                            RoundedRectangle(cornerRadius: 6)
                                .fill(bar.highlighted ? Chalk.yellow : Chalk.blue.opacity(0.75))
                                .frame(height: Swift.max(chartH * 0.85 * ratios[i] * (!animated || grown ? 1 : 0), 2))
                            Text(bar.label)
                                .font(Chalk.font(26, weight: bar.highlighted ? .bold : .medium))
                                .foregroundStyle(bar.highlighted ? Chalk.yellow : Chalk.white)
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
                                .frame(height: 34)
                        }
                        .frame(maxWidth: 120)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Chalk.white).frame(height: 3).offset(y: -42)
                }
            }
        }
        .frame(minHeight: 300)
        .task {
            guard animated else { return }
            withAnimation(.spring(duration: 0.9)) { grown = true }
        }
    }
}
