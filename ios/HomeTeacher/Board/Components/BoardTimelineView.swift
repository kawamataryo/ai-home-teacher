import SwiftUI

/// 時間の流れ。できごとを左から順に並べ、間の矢印にかかった時間を書く。
/// 段階表示（`boardRevealCount`）のときは、見せたできごとまでを描き、いちばん新しいものを強調する。
struct BoardTimelineView: View {
    let model: BoardTimeline
    @Environment(\.boardRevealCount) private var revealCount
    @Environment(\.boardFocusIndex) private var focusIndex

    var body: some View {
        // 6 個までは1行、それより多いと狭くなるので文字を縮める
        let count = Swift.max(model.events.count, 1)
        HStack(alignment: .center, spacing: 0) {
            ForEach(Array(model.events.enumerated()), id: \.offset) { i, event in
                let visible = i < revealCount
                eventCard(event, focused: i == focusIndex)
                    .opacity(visible ? 1 : 0.18)
                if i < model.events.count - 1 {
                    arrow(event.after)
                        .opacity(i + 1 < revealCount ? 1 : 0.18)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .minimumScaleFactor(count > 4 ? 0.6 : 0.8)
        .animation(.spring(duration: 0.5), value: revealCount)
    }

    private func eventCard(_ event: BoardTimeline.Event, focused: Bool) -> some View {
        VStack(spacing: 10) {
            Text(event.time)
                .font(Chalk.font(30, weight: .heavy))
                .foregroundStyle(event.time.hasPrefix("？") || event.time.hasPrefix("?") ? Chalk.pink : Chalk.yellow)
                .lineLimit(1)
            Circle()
                .fill(focused ? Chalk.yellow : Chalk.white)
                .frame(width: 22, height: 22)
            Text(event.label)
                .font(Chalk.font(26, weight: .semibold))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 10)
        .frame(minWidth: 110, maxWidth: 200)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(focused ? 0.14 : 0.06)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(focused ? Chalk.yellow : Chalk.faint, lineWidth: focused ? 4 : 2))
    }

    private func arrow(_ label: String) -> some View {
        VStack(spacing: 6) {
            Text(label)
                .font(Chalk.font(22, weight: .bold))
                .foregroundStyle(Chalk.blue)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Image(systemName: "arrow.right")
                .font(Chalk.font(30, weight: .bold))
                .foregroundStyle(Chalk.blue)
        }
        .frame(minWidth: 70, maxWidth: 130)
    }
}
