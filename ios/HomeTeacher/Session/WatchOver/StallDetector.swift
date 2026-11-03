import Foundation

/// 見守り（spec §3⑥）で StallDetector が出す出来事
enum WatchEvent: Equatable, Sendable {
    /// 集中の時間に、顔（または手）は前にあるのに手が止まったまま。値は止まっている時間（分）
    case stalled(minutes: Double)
    /// 席を立った（顔も手も動きも、しばらく見えない）
    case away
    /// 席に戻ってきた
    case returned
}

/// 映像から読み取った手の動き・顔の有無から、「手が止まっている」「席を立った」を決める（純粋なロジック。テストは合成した入力で）。
///
/// - 手が止まった時間は、集中の時間・会話が待機中・前に人がいるときだけ数える。動いた・話した・休憩に入ったら数え直す
/// - `.stalled` は止まった時間が `stallAfter` に達したときに 1 回出す。そのまま止まっていれば、さらに `stallAfter` ごとに出す（毎フレームは出さない）
/// - 顔も手も動きも `awayAfter`（初期値 30 秒）続けて見えなければ `.away`。集中の時間だけ（休憩中に席を立つのはふつう）
/// - 戻ったら `returnAfter` 続けて見えてから `.returned`（1 フレームのちらつきでは出さない）
/// - 映像が `gapLimit` より長く届かなかったら（撮影中・中断など）、その間は「わからない」として数え直す
struct StallDetector: Sendable {
    struct Configuration: Equatable, Sendable {
        var stallAfter: Duration
        var awayAfter: Duration = .seconds(30)
        var returnAfter: Duration = .seconds(1)
        var gapLimit: Duration = .seconds(5)

        /// 設定画面の「何分止まったら声をかけるか」から作る
        static func minutes(_ minutes: Int) -> Configuration {
            Configuration(stallAfter: .minutes(minutes))
        }

        var stallMinutes: Double { stallAfter / .seconds(60) }
    }

    /// 1 回分の見え方
    struct Observation: Equatable, Sendable {
        var at: ContinuousClock.Instant
        var facePresent: Bool
        var handsVisible: Bool
        /// フレーム差分か手の位置の変化で、動いていた
        var moving: Bool
        /// 子どもか先生が話している（会話が待機ではない）
        var conversationBusy: Bool = false
        /// 集中の時間（勉強モード）か
        var focusing: Bool = true
    }

    let configuration: Configuration
    private(set) var isAway = false
    private var lastObservedAt: ContinuousClock.Instant?
    /// 止まり始めた時刻
    private var stillSince: ContinuousClock.Instant?
    /// いまの止まりで `.stalled` を出した回数
    private var stallCount = 0
    private var lastPresentAt: ContinuousClock.Instant?
    /// 席を立っている間に、続けて見え始めた時刻
    private var presentSince: ContinuousClock.Instant?

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    mutating func observe(_ o: Observation) -> [WatchEvent] {
        var events: [WatchEvent] = []
        if let last = lastObservedAt, o.at - last > configuration.gapLimit {
            resetBaseline(at: o.at)
        } else if lastObservedAt == nil {
            resetBaseline(at: o.at)
        }
        lastObservedAt = o.at

        let present = o.facePresent || o.handsVisible || o.moving || o.conversationBusy
        if present {
            lastPresentAt = o.at
            if isAway {
                let since = presentSince ?? o.at
                presentSince = since
                if o.at - since >= configuration.returnAfter {
                    isAway = false
                    presentSince = nil
                    events.append(.returned)
                }
            }
        } else {
            presentSince = nil
            if !isAway, o.focusing, let lastPresentAt, o.at - lastPresentAt >= configuration.awayAfter {
                isAway = true
                events.append(.away)
            }
        }

        if !o.focusing || isAway || !present || o.moving || o.conversationBusy {
            stillSince = o.at
            stallCount = 0
        } else if let stillSince {
            let still = o.at - stillSince
            if still >= configuration.stallAfter * (stallCount + 1) {
                stallCount += 1
                events.append(.stalled(minutes: still / .seconds(60)))
            }
        }
        return events
    }

    /// 数え直す（撮影から戻ったときなど）。席を立っているかはそのまま
    mutating func resetBaseline(at instant: ContinuousClock.Instant) {
        stillSince = instant
        stallCount = 0
        lastPresentAt = instant
        presentSince = nil
        lastObservedAt = instant
    }
}

/// 映像 1 枚から読み取ったもの。映像そのものは持たない（端末の外にも出さず、保存もしない）
struct ActivitySample: Equatable, Sendable {
    var facePresent: Bool
    var handsVisible: Bool
    /// 下の方（ノートと手のあたり）のフレーム差分（0〜1）
    var frameMotion: Double
    /// 手の位置の変化（画面の幅を 1 とした移動量）。手が見えなければ nil
    var handMotion: Double?

    var isMoving: Bool { MotionEstimator.isMoving(frameMotion: frameMotion, handMotion: handMotion) }
}

/// フレーム差分と手の位置の変化の計算（純粋な関数）
enum MotionEstimator {
    /// これより大きいフレーム差分なら動いている（実機で調整する）
    static let frameMotionThreshold = 0.025
    /// これより大きい手の移動なら動いている
    static let handMotionThreshold = 0.02

    static func isMoving(frameMotion: Double, handMotion: Double?) -> Bool {
        frameMotion > frameMotionThreshold || (handMotion ?? 0) > handMotionThreshold
    }

    /// 2 つの小さな濃淡の格子（0〜255）の差の平均（0〜1）。大きさが違えば 0
    static func frameDifference(_ previous: [UInt8], _ current: [UInt8]) -> Double {
        guard !previous.isEmpty, previous.count == current.count else { return 0 }
        var total = 0
        for i in previous.indices { total += abs(Int(previous[i]) - Int(current[i])) }
        return Double(total) / Double(previous.count) / 255
    }

    /// 手の点の移動量。今の点それぞれについて、前のいちばん近い点との距離をとり、その最大
    static func handDisplacement(_ previous: [CGPoint], _ current: [CGPoint]) -> Double? {
        guard !previous.isEmpty, !current.isEmpty else { return nil }
        return current.map { point in
            previous.map { hypot(Double($0.x - point.x), Double($0.y - point.y)) }.min() ?? 0
        }.max()
    }
}
