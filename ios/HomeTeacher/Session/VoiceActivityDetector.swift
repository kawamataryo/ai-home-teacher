import Foundation

/// マイクの音量（RMS）と認識結果の届き方から、子どもが話しているかを決める。
///
/// - 音量は開くしきい値と閉じるしきい値をずらし（ヒステリシス）、短い物音や息継ぎでぱたぱたしないようにする
///   - `startThreshold` 以上が `attack` 続いたら話し始め
///   - `endThreshold` 未満が `release` 続いたら話し終わり
/// - 認識結果（書き起こし）が新しく届いたら、音量が小さくても話しているとみなす。
///   実機（#9 / #13）ではエコーキャンセル ON で先生の声が認識に入らなかったので、文字は音量より確かな手がかりになる
///   - 最後に文字が届いてから `textHold` は話し終わりにしない
///
/// AVFoundation に依存しない値型。時刻は呼び出し側が渡すので、テストでそのまま確かめられる。
struct VoiceActivityDetector: Sendable {
    enum Change: Equatable, Sendable {
        case started
        case ended
    }

    var startThreshold: Float
    var endThreshold: Float
    var attack: Duration
    var release: Duration
    var textHold: Duration

    private(set) var isActive = false
    /// `startThreshold` を超え始めた時刻（話し始めの判定中）
    private var aboveSince: ContinuousClock.Instant?
    /// 最後に `endThreshold` 以上だった時刻
    private var lastLoudAt: ContinuousClock.Instant?
    /// 最後に書き起こしが届いた時刻
    private var lastTextAt: ContinuousClock.Instant?

    /// 実機で調整する前提の初期値。エコーキャンセル ON の入力は音量が小さめになる
    init(
        startThreshold: Float = 0.02,
        endThreshold: Float = 0.01,
        attack: Duration = .milliseconds(120),
        release: Duration = .milliseconds(350),
        textHold: Duration = .milliseconds(600)
    ) {
        self.startThreshold = startThreshold
        self.endThreshold = max(0, min(endThreshold, startThreshold))
        self.attack = attack
        self.release = release
        self.textHold = textHold
    }

    /// 音量を 1 回分渡す。状態が変わったらその変化を返す
    mutating func process(level: Float, at now: ContinuousClock.Instant) -> Change? {
        if level >= endThreshold { lastLoudAt = now }
        if isActive { return endIfQuiet(at: now) }
        guard level >= startThreshold else {
            aboveSince = nil
            return nil
        }
        if aboveSince == nil { aboveSince = now }
        guard let since = aboveSince, now - since >= attack else { return nil }
        return activate()
    }

    /// 新しい書き起こしが届いた。話していなければ話し始めにする
    mutating func noteText(at now: ContinuousClock.Instant) -> Change? {
        lastTextAt = now
        return isActive ? nil : activate()
    }

    /// 途中の判定を捨てて、話していない状態に戻す（マイクを止めたときなど）
    mutating func reset() {
        isActive = false
        aboveSince = nil
        lastLoudAt = nil
        lastTextAt = nil
    }

    /// 音量が `release`、文字が `textHold` のあいだ途切れていたら話し終わり
    private mutating func endIfQuiet(at now: ContinuousClock.Instant) -> Change? {
        if let lastLoudAt, now - lastLoudAt < release { return nil }
        if let lastTextAt, now - lastTextAt < textHold { return nil }
        isActive = false
        aboveSince = nil
        return .ended
    }

    private mutating func activate() -> Change {
        isActive = true
        aboveSince = nil
        return .started
    }
}
