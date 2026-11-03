import SwiftUI

/// 残り時間をリングで見せる表示。値だけを受け取るので、プレビューやスクショにも使える。
struct FocusTimerIndicator: View {
    let phase: FocusPhase
    let status: FocusTimerStatus
    let remaining: Duration
    let total: Duration

    private var progress: Double {
        guard total > .zero else { return 0 }
        return min(1, max(0, remaining / total))
    }

    private var tint: Color {
        switch phase {
        case .focus: .orange
        case .rest: .teal
        }
    }

    private var label: String {
        switch (status, phase) {
        case (.stopped, _): "まだ始めていない"
        case (.paused, _): "ひと休み中（止めてるよ）"
        case (.running, .focus): "集中"
        case (.running, .rest): "休憩"
        }
    }

    private var timeText: String {
        let seconds = Int(remaining.components.seconds)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(tint.opacity(0.2), lineWidth: 12)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(tint, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: progress)
                VStack(spacing: 2) {
                    Image(systemName: phase == .focus ? "pencil" : "cup.and.saucer.fill")
                        .foregroundStyle(tint)
                    Text(timeText)
                        .font(.title2.monospacedDigit().bold())
                }
            }
            // 集中と休憩が切り替わったときに、色が混ざりながら変わらないよう作り直す
            .id(phase)
            .frame(width: 120, height: 120)
            Text(label)
                .font(.headline)
                .foregroundStyle(status == .paused ? .secondary : tint)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) のこり \(timeText)")
    }
}

/// `FocusTimer` を 1 秒ごとに読み直して表示する。
struct FocusTimerView: View {
    let timer: FocusTimer

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            FocusTimerIndicator(
                phase: timer.phase,
                status: timer.status,
                remaining: timer.remaining,
                total: timer.currentPhaseDuration
            )
        }
    }
}

/// タイマー表示の確認用画面（ContentView から開く）。
struct FocusTimerPreviewScreen: View {
    /// 確認しやすいよう、集中 1 分・休憩 30 秒で動かす
    @State private var timer = FocusTimer(
        clock: SystemConversationClock(),
        settings: FocusTimerSettings(focusDuration: .seconds(60), breakDuration: .seconds(30))
    )

    var body: some View {
        VStack(spacing: 40) {
            HStack(spacing: 48) {
                FocusTimerIndicator(phase: .focus, status: .running, remaining: .seconds(18 * 60 + 42), total: .minutes(25))
                FocusTimerIndicator(phase: .rest, status: .running, remaining: .seconds(3 * 60 + 5), total: .minutes(5))
                FocusTimerIndicator(phase: .focus, status: .paused, remaining: .seconds(7 * 60 + 30), total: .minutes(25))
            }
            Divider()
            VStack(spacing: 16) {
                Text("動かしてみる（集中 1 分・休憩 30 秒）")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                FocusTimerView(timer: timer)
                HStack(spacing: 16) {
                    Button("はじめる") { timer.start() }
                    Button(timer.status == .paused ? "つづける" : "一時停止") {
                        if timer.status == .paused { timer.resume() } else { timer.pause() }
                    }
                    .disabled(timer.status == .stopped)
                    Button("おわる") { timer.stop() }
                        .disabled(timer.status == .stopped)
                }
                .buttonStyle(.bordered)
                Text(timer.isOnBreak ? "休憩中：雑談モード" : "勉強モード")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .navigationTitle("集中・休憩タイマー")
    }
}

#Preview {
    NavigationStack { FocusTimerPreviewScreen() }
}
