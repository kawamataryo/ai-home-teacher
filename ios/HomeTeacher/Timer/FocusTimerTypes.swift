import Foundation

/// 集中と休憩のどちらの時間か。
enum FocusPhase: Equatable, Sendable {
    /// 集中（勉強）の時間
    case focus
    /// 休憩の時間。先生は雑談モードになる（プロンプトの切り替えは #26）
    case rest
}

/// タイマーが動いているか。
enum FocusTimerStatus: Equatable, Sendable {
    /// 始まっていない（またはセッションが終わった）
    case stopped
    case running
    /// 一時停止中（席を立ったときなど）。残り時間は止まる
    case paused
}

/// FocusTimer が外へ知らせる出来事。
enum FocusTimerEvent: Equatable, Sendable {
    /// 集中または休憩が始まった。休憩なら雑談モードに切り替える合図
    case phaseStarted(FocusPhase)
    case paused
    case resumed
    case stopped
}

/// 先生の定型句。キーは定型句キャッシュ（#12）で事前生成した音声を引くのに使う。
enum FixedPhrase: String, CaseIterable, Sendable {
    /// 集中の終わり
    case breakTime = "break_time"
    /// 休憩の終わり
    case breakOver = "break_over"
    /// 集中の終わり 5 分前の励まし
    case fiveMinutesLeft = "five_minutes_left"

    var text: String {
        switch self {
        case .breakTime: "そろそろ休憩しよっか"
        case .breakOver: "休憩おわり！続きやろう"
        case .fiveMinutesLeft: "あと5分がんばろう"
        }
    }
}

/// 先生から自分でかける声かけ。
struct TeacherNudge: Equatable, Sendable {
    let phrase: FixedPhrase
    /// true なら言い回しを Haiku に変えてもらってよい（false なら定型句をそのまま、キャッシュの音声で話す）
    let allowsVariation: Bool

    init(_ phrase: FixedPhrase, allowsVariation: Bool = false) {
        self.phrase = phrase
        self.allowsVariation = allowsVariation
    }

    /// 定型句のまま話すときの文
    var text: String { phrase.text }
}

/// タイマーの設定。分数と言い回しは設定画面の値（SessionPreferences）を、セッションを始めるときに読む（#65）。
struct FocusTimerSettings: Equatable, Sendable {
    var focusDuration: Duration
    var breakDuration: Duration
    /// 集中の終わり 5 分前に「あと5分がんばろう」と声をかけるか（集中が 5 分以下なら声をかけない）
    var encouragesBeforeFocusEnds: Bool
    /// 声かけの言い回しを Haiku に変えてもらってよいか
    var allowsVariation: Bool

    /// 励ましを出す、集中の終わりまでの残り時間。定型句「あと5分」に合わせて固定
    static let encouragementLead: Duration = .minutes(5)

    init(
        focusDuration: Duration = .minutes(25),
        breakDuration: Duration = .minutes(5),
        encouragesBeforeFocusEnds: Bool = true,
        allowsVariation: Bool = false
    ) {
        self.focusDuration = focusDuration
        self.breakDuration = breakDuration
        self.encouragesBeforeFocusEnds = encouragesBeforeFocusEnds
        self.allowsVariation = allowsVariation
    }

    func duration(of phase: FocusPhase) -> Duration {
        switch phase {
        case .focus: focusDuration
        case .rest: breakDuration
        }
    }
}

extension Duration {
    static func minutes(_ value: Int) -> Duration { .seconds(value * 60) }
}
