import Foundation
import Observation

/// 集中（既定 25 分）→ 休憩（既定 5 分）→ 集中… をくり返すタイマー。
///
/// - 区切りで `NudgeSink` に声かけを渡す（集中の終わり・休憩の終わり・集中の終わり 5 分前）
/// - 休憩中は `isOnBreak` が true になり、`.phaseStarted(.rest)` を出す。雑談モードへの切り替えは受け取った側（#26）
/// - 一時停止すると残り時間が止まり、再開すると続きから数える
///
/// 時計は `ConversationClock` で受け取るので、テストでは手で進められる。
@MainActor
@Observable
final class FocusTimer {
    private(set) var status: FocusTimerStatus = .stopped
    private(set) var phase: FocusPhase = .focus
    /// 終えた集中の回数
    private(set) var completedFocusCount = 0

    let settings: FocusTimerSettings
    /// 出来事の通知。AsyncStream なので購読者は 1 つだけ
    let events: AsyncStream<FocusTimerEvent>

    @ObservationIgnored private let eventContinuation: AsyncStream<FocusTimerEvent>.Continuation
    @ObservationIgnored private let clock: any ConversationClock
    @ObservationIgnored private let nudgeSink: (any NudgeSink)?

    /// 最後に動き始めた（開始・再開した）時点での、いまの区切りの残り時間
    @ObservationIgnored private var remainingAtResume: Duration = .zero
    /// 最後に動き始めた時刻。止まっている間は nil
    @ObservationIgnored private var resumedAt: ContinuousClock.Instant?
    /// いまの集中で励ましをもう出したか（一時停止→再開で 2 回出さないため）
    @ObservationIgnored private var hasEncouraged = false
    @ObservationIgnored private var phaseEndTimer: (any ScheduledAction)?
    @ObservationIgnored private var encouragementTimer: (any ScheduledAction)?

    init(clock: any ConversationClock, settings: FocusTimerSettings = FocusTimerSettings(), nudgeSink: (any NudgeSink)? = nil) {
        self.clock = clock
        self.settings = settings
        self.nudgeSink = nudgeSink
        (events, eventContinuation) = AsyncStream.makeStream(of: FocusTimerEvent.self)
    }

    /// 休憩中か（一時停止中も含む）。プロンプトを雑談モードにするかの判断に使う
    var isOnBreak: Bool { status != .stopped && phase == .rest }

    /// いまの区切りの残り時間
    var remaining: Duration {
        guard let resumedAt else { return remainingAtResume }
        return max(.zero, remainingAtResume - (clock.now - resumedAt))
    }

    /// いまの区切りの長さ（表示の割合に使う）
    var currentPhaseDuration: Duration { settings.duration(of: phase) }

    // MARK: - 操作

    /// 集中から始める（学習セッションの開始）。動いていたら最初からやり直す
    func start() {
        completedFocusCount = 0
        begin(.focus)
    }

    /// 一時停止する。残り時間を止め、予約した声かけも止める
    func pause() {
        guard status == .running else { return }
        remainingAtResume = remaining
        resumedAt = nil
        cancelTimers()
        status = .paused
        eventContinuation.yield(.paused)
    }

    /// 一時停止から続きを数える
    func resume() {
        guard status == .paused else { return }
        status = .running
        run()
        eventContinuation.yield(.resumed)
    }

    /// 集中の途中で休憩に入る（子どもが「休憩したい」と言った）。集中の途中でなければ何もせず false
    @discardableResult
    func startBreakNow() -> Bool {
        guard status == .running, phase == .focus else { return false }
        begin(.rest)
        return true
    }

    /// 止める（学習セッションの終了）
    func stop() {
        guard status != .stopped else { return }
        cancelTimers()
        resumedAt = nil
        remainingAtResume = .zero
        status = .stopped
        phase = .focus
        eventContinuation.yield(.stopped)
    }

    // MARK: - 内部

    private func begin(_ next: FocusPhase) {
        cancelTimers()
        phase = next
        hasEncouraged = false
        remainingAtResume = settings.duration(of: next)
        status = .running
        run()
        eventContinuation.yield(.phaseStarted(next))
    }

    /// 残り時間から、区切りと励ましを予約する
    private func run() {
        resumedAt = clock.now
        let left = remainingAtResume
        phaseEndTimer = clock.schedule(after: left) { [weak self] in
            self?.finishPhase()
        }

        let lead = FocusTimerSettings.encouragementLead
        if phase == .focus, settings.encouragesBeforeFocusEnds, !hasEncouraged,
           settings.focusDuration > lead, left > lead {
            encouragementTimer = clock.schedule(after: left - lead) { [weak self] in
                guard let self else { return }
                self.hasEncouraged = true
                self.nudge(.fiveMinutesLeft)
            }
        }
    }

    private func finishPhase() {
        guard status == .running else { return }
        switch phase {
        case .focus:
            completedFocusCount += 1
            nudge(.breakTime)
            begin(.rest)
        case .rest:
            nudge(.breakOver)
            begin(.focus)
        }
    }

    private func nudge(_ phrase: FixedPhrase) {
        nudgeSink?.deliver(TeacherNudge(phrase, allowsVariation: settings.allowsVariation))
    }

    private func cancelTimers() {
        phaseEndTimer?.cancel()
        phaseEndTimer = nil
        encouragementTimer?.cancel()
        encouragementTimer = nil
    }
}
