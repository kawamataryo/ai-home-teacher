import SwiftUI

/// 手順カード。1枚ずつ順に出てくる。
/// 段階表示（`boardRevealCount`）のときは、まだのカードを番号だけの薄い枠で見せ、いま話しているカード（`boardFocusIndex`）を目立たせる。
struct StepCardsView: View {
    let model: StepCards
    @Environment(\.boardAnimated) private var animated
    @Environment(\.boardRevealCount) private var revealCount
    @Environment(\.boardFocusIndex) private var focusIndex
    @State private var appeared = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(model.steps.enumerated()), id: \.offset) { i, step in
                let isLast = i == model.steps.count - 1
                Group {
                    if i < revealCount {
                        card(number: i + 1, step: step, isLast: isLast, focused: i == focusIndex)
                            .transition(.asymmetric(insertion: .move(edge: .leading).combined(with: .opacity), removal: .opacity))
                    } else {
                        placeholder(number: i + 1)
                    }
                }
                .opacity(hasAppeared(i) ? 1 : 0)
                .offset(x: hasAppeared(i) ? 0 : -40)
            }
            Spacer(minLength: 0)
        }
        .animation(.spring(duration: 0.5), value: revealCount)
        .animation(.easeInOut(duration: 0.3), value: focusIndex)
        .task {
            guard animated else { return }
            for i in model.steps.indices {
                try? await Task.sleep(for: .milliseconds(i == 0 ? 150 : 500))
                withAnimation(.spring(duration: 0.5)) { appeared = i + 1 }
            }
        }
    }

    /// 最初に出てくるときのアニメーション（段階表示とは別）。
    private func hasAppeared(_ i: Int) -> Bool { !animated || i < appeared }

    private func card(number: Int, step: StepCards.Step, isLast: Bool, focused: Bool) -> some View {
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
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(focused ? 0.14 : 0.07)))
        .overlay(
            RoundedRectangle(cornerRadius: 16).strokeBorder(
                focused ? Chalk.yellow : Chalk.faint,
                style: StrokeStyle(lineWidth: focused ? 4 : 2, dash: focused ? [] : [8, 6])
            )
        )
    }

    /// まだ見せていないカード。何枚あるかだけわかるようにする。
    private func placeholder(number: Int) -> some View {
        HStack(spacing: 20) {
            Text("\(number)")
                .font(Chalk.font(30, weight: .heavy))
                .foregroundStyle(Chalk.faint)
                .frame(width: 56, height: 56)
                .overlay(Circle().strokeBorder(Chalk.faint, style: StrokeStyle(lineWidth: 2, dash: [6, 5])))
            Text("？")
                .font(Chalk.font(30, weight: .bold))
                .foregroundStyle(Chalk.faint)
            Spacer(minLength: 0)
        }
        .padding(18)
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Chalk.faint.opacity(0.5), style: StrokeStyle(lineWidth: 2, dash: [8, 6])))
    }
}
