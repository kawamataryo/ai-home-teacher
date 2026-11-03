import Foundation
import Testing
@testable import HomeTeacher

/// 見守りの判定（#30）。入力は合成した見え方
struct StallDetectorTests {
    private let start = ContinuousClock.now

    private enum Look {
        case moving, still, empty, faceOnly

        func observation(at: ContinuousClock.Instant, busy: Bool = false, focusing: Bool = true) -> StallDetector.Observation {
            switch self {
            case .moving: .init(at: at, facePresent: true, handsVisible: true, moving: true, conversationBusy: busy, focusing: focusing)
            case .still: .init(at: at, facePresent: true, handsVisible: true, moving: false, conversationBusy: busy, focusing: focusing)
            case .faceOnly: .init(at: at, facePresent: true, handsVisible: false, moving: false, conversationBusy: busy, focusing: focusing)
            case .empty: .init(at: at, facePresent: false, handsVisible: false, moving: false, conversationBusy: busy, focusing: focusing)
            }
        }
    }

    /// `from` 秒から `to` 秒まで、`step` 秒おきに同じ見え方を流し、出た出来事を（秒, 出来事）で返す
    private func feed(
        _ detector: inout StallDetector, _ look: Look, from: Int, to: Int, step: Int = 1, busy: Bool = false, focusing: Bool = true
    ) -> [(Int, WatchEvent)] {
        var events: [(Int, WatchEvent)] = []
        for second in Swift.stride(from: from, through: to, by: step) {
            for event in detector.observe(look.observation(at: start + .seconds(second), busy: busy, focusing: focusing)) {
                events.append((second, event))
            }
        }
        return events
    }

    private func detector(minutes: Int = 3) -> StallDetector {
        StallDetector(configuration: .minutes(minutes))
    }

    @Test func 手が設定の分だけ止まったら1回だけ知らせる() {
        var d = detector(minutes: 3)
        let events = feed(&d, .still, from: 0, to: 200)
        #expect(events.count == 1)
        #expect(events.first?.0 == 180)
        #expect(events.first?.1 == .stalled(minutes: 3))
    }

    @Test func 止まったままならさらに設定の分ごとに知らせる() {
        var d = detector(minutes: 2)
        let events = feed(&d, .faceOnly, from: 0, to: 370)
        #expect(events.map(\.0) == [120, 240, 360])
    }

    @Test func 動いたら数え直す() {
        var d = detector(minutes: 3)
        #expect(feed(&d, .still, from: 0, to: 170).isEmpty)
        #expect(feed(&d, .moving, from: 171, to: 172).isEmpty)
        let events = feed(&d, .still, from: 173, to: 360)
        #expect(events.map(\.0) == [352])
    }

    @Test func 話している間は数えない() {
        var d = detector(minutes: 2)
        #expect(feed(&d, .still, from: 0, to: 300, busy: true).isEmpty)
        // 話し終わってから数え始める
        #expect(feed(&d, .still, from: 301, to: 421).map(\.0) == [420])
    }

    @Test func 休憩中は数えず席を立ってもタイマーを止めない() {
        var d = detector(minutes: 2)
        #expect(feed(&d, .still, from: 0, to: 300, focusing: false).isEmpty)
        #expect(feed(&d, .empty, from: 301, to: 400, focusing: false).isEmpty)
    }

    @Test func 映像が届かなかった間は数えない() {
        var d = detector(minutes: 3)
        #expect(feed(&d, .still, from: 0, to: 100).isEmpty)
        // 撮影などで 60 秒届かなかった → その間は数えず、届いたところから数え直す
        let events = feed(&d, .still, from: 160, to: 345)
        #expect(events.map(\.0) == [340])
    }

    @Test func 顔も手も30秒見えなければ席を立ったと知らせ戻ったら知らせる() {
        var d = detector(minutes: 3)
        #expect(feed(&d, .still, from: 0, to: 10).isEmpty)
        let away = feed(&d, .empty, from: 11, to: 60)
        #expect(away.count == 1)
        #expect(away.first?.0 == 40)
        #expect(away.first?.1 == .away)
        #expect(d.isAway)
        // 戻ってから 1 秒見え続けたら戻ったとみなす
        let back = feed(&d, .faceOnly, from: 61, to: 63)
        #expect(back.map(\.0) == [62])
        #expect(back.map(\.1) == [.returned])
        #expect(!d.isAway)
    }

    @Test func 一瞬見えただけでは戻ったとみなさない() {
        var d = detector(minutes: 3)
        _ = feed(&d, .empty, from: 0, to: 40)
        #expect(d.isAway)
        #expect(feed(&d, .faceOnly, from: 41, to: 41).isEmpty)
        #expect(feed(&d, .empty, from: 42, to: 50).isEmpty)
        #expect(d.isAway)
    }

    @Test func 一瞬顔が見えなくなっても席を立ったとはみなさない() {
        var d = detector(minutes: 3)
        _ = feed(&d, .still, from: 0, to: 10)
        var events = feed(&d, .empty, from: 11, to: 30)
        events += feed(&d, .faceOnly, from: 31, to: 31)
        events += feed(&d, .empty, from: 32, to: 55)
        #expect(events.isEmpty)
        #expect(!d.isAway)
    }

    @Test func 席を立っている間は手が止まったとはみなさない() {
        var d = detector(minutes: 2)
        let events = feed(&d, .empty, from: 0, to: 600)
        #expect(events.map(\.1) == [.away])
    }

    @Test func 戻ってから数え直す() {
        var d = detector(minutes: 2)
        _ = feed(&d, .empty, from: 0, to: 100)
        let events = feed(&d, .faceOnly, from: 101, to: 230)
        #expect(events.map(\.1) == [.returned, .stalled(minutes: 2)])
        #expect(events.last?.0 == 221)
    }

    @Test func 設定はオフと2分3分5分() {
        #expect(SessionPreferences.watchOverChoices == [0, 2, 3, 5])
        #expect(StallDetector.Configuration.minutes(5).stallAfter == .seconds(300))
        #expect(StallDetector.Configuration.minutes(3).awayAfter == .seconds(30))
    }
}

struct MotionEstimatorTests {
    @Test func フレーム差分は格子の差の平均() {
        #expect(MotionEstimator.frameDifference([0, 0, 0, 0], [0, 0, 0, 0]) == 0)
        #expect(MotionEstimator.frameDifference([0, 0], [255, 255]) == 1)
        #expect(abs(MotionEstimator.frameDifference([100, 100], [110, 90]) - 10.0 / 255) < 1e-9)
        // 最初のフレーム・大きさが違うときは動いていないとみなす
        #expect(MotionEstimator.frameDifference([], [1, 2]) == 0)
    }

    @Test func 手の移動はいちばん近い点との距離の最大() throws {
        let previous = [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.5, y: 0.5)]
        let current = [CGPoint(x: 0.1, y: 0.13), CGPoint(x: 0.5, y: 0.5)]
        let displacement = try #require(MotionEstimator.handDisplacement(previous, current))
        #expect(abs(displacement - 0.03) < 1e-6)
        #expect(MotionEstimator.handDisplacement([], current) == nil)
    }

    @Test func どちらかが大きければ動いている() {
        #expect(ActivitySample(facePresent: true, handsVisible: false, frameMotion: 0.1, handMotion: nil).isMoving)
        #expect(ActivitySample(facePresent: true, handsVisible: true, frameMotion: 0, handMotion: 0.05).isMoving)
        #expect(!ActivitySample(facePresent: true, handsVisible: true, frameMotion: 0.005, handMotion: 0.005).isMoving)
    }
}

struct ConsentDetectorTests {
    @Test(arguments: ["うん", "うん、いいよ", "はい", "いいよ", "見て", "これ見て", "うーん、わかんない", "お願い", "どうぞ"])
    func 見せてよいという返事(_ text: String) {
        #expect(ConsentDetector.isConsent(text))
    }

    @Test(arguments: ["だいじょうぶ", "大丈夫、自分でやる", "ううん", "いや、いい", "あとで", "いいです", "まだ考えてる", ""])
    func 断りやそれ以外の返事(_ text: String) {
        #expect(!ConsentDetector.isConsent(text))
    }
}
