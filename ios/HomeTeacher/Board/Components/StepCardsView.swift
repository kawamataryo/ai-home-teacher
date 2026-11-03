import SwiftUI

/// 手順カード。1枚ずつ順に出てくる。
struct StepCardsView: View {
    let model: StepCards
    @Environment(\.boardAnimated) private var animated
    @State private var revealed = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(model.steps.enumerated()), id: \.offset) { i, step in
                card(number: i + 1, step: step, isLast: i == model.steps.count - 1)
                    .opacity(isVisible(i) ? 1 : 0)
                    .offset(x: isVisible(i) ? 0 : -40)
            }
            Spacer(minLength: 0)
        }
        .task {
            guard animated else { return }
            for i in model.steps.indices {
                try? await Task.sleep(for: .milliseconds(i == 0 ? 150 : 700))
                withAnimation(.spring(duration: 0.5)) { revealed = i + 1 }
            }
        }
    }

    private func isVisible(_ i: Int) -> Bool { !animated || i < revealed }

    private func card(number: Int, step: StepCards.Step, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 20) {
            Text("\(number)")
                .font(Chalk.font(30, weight: .heavy))
                .foregroundStyle(Chalk.boardDeep)
                .frame(width: 56, height: 56)
                .background(Circle().fill(isLast ? Chalk.pink : Chalk.yellow))
            VStack(alignment: .leading, spacing: 6) {
                Text(step.heading)
                    .font(Chalk.font(30, weight: .bold))
                    .foregroundStyle(isLast ? Chalk.pink : Chalk.yellow)
                Text(step.detail)
                    .font(Chalk.font(26, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Chalk.faint, style: StrokeStyle(lineWidth: 2, dash: [8, 6])))
    }
}
