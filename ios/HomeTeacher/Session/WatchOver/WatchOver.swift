import Foundation
import Observation
import OSLog
import UIKit

// 見守り（spec §3⑥・#30）。端末内の Vision で手の動きと顔の有無だけを見て、
// 手が止まっていたら「どこか考え中？ちょっと見せて？」と聞き、子どもが同意したら撮影する（同意なしには撮らない）。
// 席を立ったら（集中の時間だけ）タイマーを止め、戻ったら続きから数える。

/// 映像から手の動き・顔の有無を読み取るもの。本物は ActivityWatcher（AVFoundation + Vision）。テストや自己テストでは合成した値を流す
@MainActor
protocol ActivityWatching: AnyObject {
    /// 読み取るたびに呼ぶ（数百 ms ごと）
    var onSample: (@MainActor (ActivitySample) -> Void)? { get set }
    func start() async throws
    /// 止める。戻ったときにはカメラは止まっている（撮影のカメラに渡せる）
    func stop() async
}

/// 「今、声をかけるべきか」。JevNudgeJudge（Jev が使えなければ規則）か、規則だけ
@MainActor
protocol NudgeJudging: AnyObject {
    func shouldSpeakUp(_ context: NudgeContext) async -> Bool
}

extension JevNudgeJudge: NudgeJudging {}

/// Jev を使わないときの規則（`JevNudgeJudge.ruleShouldSpeakUp`）
@MainActor
final class RuleNudgeJudge: NudgeJudging {
    let stalledMinutesThreshold: Double

    init(stalledMinutesThreshold: Double) {
        self.stalledMinutesThreshold = stalledMinutesThreshold
    }

    func shouldSpeakUp(_ context: NudgeContext) async -> Bool {
        JevNudgeJudge.ruleShouldSpeakUp(context, stalledMinutesThreshold: stalledMinutesThreshold)
    }
}

/// 見守りから学習セッション（StudySessionCoordinator）に頼むこと
@MainActor
protocol WatchOverHost: AnyObject {
    /// セッション中で、集中の時間（勉強モード）か。席を立って止めている間も true
    var watchOverIsFocusing: Bool { get }
    /// 会話が待機中で、撮影もしていない（声をかけてよい）
    var watchOverIsQuiet: Bool { get }
    /// 先生が声をかける。話せたら true（話し始める前に子どもが話し始めたら false）
    func watchOverCheckIn(_ sentences: [String]) async -> Bool
    /// タイマーを止める。止めたら true（動いていなければ false）
    func watchOverPauseTimer() -> Bool
    func watchOverResumeTimer()
    func watchOverTrace(_ message: String)
}

/// 学習セッションから見守りに伝えること
@MainActor
protocol WatchOverControlling: AnyObject {
    func sessionStarted(host: any WatchOverHost)
    func sessionEnded()
    /// 声かけ（ちょっと見せて？）への返事なら受け取り、撮ってよいなら true。返事を待っていなければ false
    func consumeConsent(_ utterance: String) -> Bool
}

/// 見守りの本体。カメラ（ActivityWatching）・StallDetector・声をかけるかの判断・同意の待ち受けをまとめる
@MainActor
@Observable
final class WatchOver: WatchOverControlling {
    /// 手が止まったときの声かけ。2 文目は定型句（音声を同梱済み）
    static let checkInLines = ["どこか考え中？", "ちょっと見せて？"]
    /// 声かけのあと、返事を同意として受け取る時間（ConversationSettings の continuationWindow と同じ）
    static let consentWindow: Duration = .seconds(30)
    /// 撮影のカメラが止まってから見守りのカメラを動かすまでの間
    static let resumeDelay: Duration = .milliseconds(500)

    /// 見守りのカメラが動いている（画面に「見守りカメラ オン」を出す）
    private(set) var isWatching = false
    /// 声かけへの返事を待っている
    private(set) var isAwaitingConsent = false

    @ObservationIgnored private let watcher: any ActivityWatching
    @ObservationIgnored private let clock: any ConversationClock
    /// セッションを始めるときに読む設定。nil なら見守りはオフ（カメラも許可も使わない）
    @ObservationIgnored private let configuration: @MainActor () -> StallDetector.Configuration?
    @ObservationIgnored private let makeJudge: @MainActor (StallDetector.Configuration) -> any NudgeJudging
    @ObservationIgnored private let logger = Logger(subsystem: "com.kawamataryo.HomeTeacher", category: "WatchOver")

    @ObservationIgnored private weak var host: (any WatchOverHost)?
    @ObservationIgnored private(set) var detector: StallDetector?
    @ObservationIgnored private var judge: (any NudgeJudging)?
    @ObservationIgnored private var cameraTask: Task<Void, Never>?
    @ObservationIgnored private var checkInTask: Task<Void, Never>?
    @ObservationIgnored private var consentDeadline: ContinuousClock.Instant?
    /// 返事がないまま待ち受けの時間が過ぎたら閉じる（閉じないと次の声かけができない）
    @ObservationIgnored private var consentExpiry: (any ScheduledAction)?
    @ObservationIgnored private var isSuspendedForCapture = false
    /// 席を立ったので見守りがタイマーを止めた（戻ったら動かすのはこのときだけ）
    @ObservationIgnored private(set) var pausedTimer = false
    /// 最後に会話が動いていた（誰かが話していた）時刻
    @ObservationIgnored private var lastBusyAt: ContinuousClock.Instant?
    @ObservationIgnored private var sampleCount = 0
    @ObservationIgnored private var movingCount = 0

    init(
        watcher: any ActivityWatching,
        clock: any ConversationClock,
        configuration: @escaping @MainActor () -> StallDetector.Configuration?,
        makeJudge: @escaping @MainActor (StallDetector.Configuration) -> any NudgeJudging
    ) {
        self.watcher = watcher
        self.clock = clock
        self.configuration = configuration
        self.makeJudge = makeJudge
        watcher.onSample = { [weak self] in self?.handle($0) }
    }

    /// Jev が使えれば JevNudgeJudge（使えなければ規則）、なければ規則だけで判断する
    static func judgeFactory(decisions: TeacherDecisions?) -> @MainActor (StallDetector.Configuration) -> any NudgeJudging {
        { configuration in
            if let decisions {
                JevNudgeJudge(decisions: decisions, stalledMinutesThreshold: configuration.stallMinutes)
            } else {
                RuleNudgeJudge(stalledMinutesThreshold: configuration.stallMinutes)
            }
        }
    }

    // MARK: - セッション

    func sessionStarted(host: any WatchOverHost) {
        self.host = host
        guard let configuration = configuration() else {
            trace("見守り: オフ（設定）")
            return
        }
        detector = StallDetector(configuration: configuration)
        judge = makeJudge(configuration)
        lastBusyAt = clock.now
        trace("見守り: 手が \(Self.format(configuration.stallMinutes)) 分止まったら声をかける・顔が \(Int(configuration.awayAfter / .seconds(1))) 秒見えなければタイマーを止める")
        startCamera()
    }

    func sessionEnded() {
        let wasWatching = detector != nil
        detector = nil
        judge = nil
        checkInTask?.cancel()
        checkInTask = nil
        endConsentWindow()
        pausedTimer = false
        isSuspendedForCapture = false
        host = nil
        guard wasWatching else { return }
        let previous = cameraTask
        cameraTask = Task { [weak self] in
            await previous?.value
            await self?.watcher.stop()
            self?.isWatching = false
        }
    }

    func consumeConsent(_ utterance: String) -> Bool {
        guard let deadline = consentDeadline else { return false }
        endConsentWindow()
        guard clock.now <= deadline else { return false }
        let agreed = ConsentDetector.isConsent(utterance)
        trace("見守りの声かけへの返事「\(utterance)」→ \(agreed ? "見せてくれる（撮影する）" : "撮らない（ふつうに返事する）")")
        return agreed
    }

    // MARK: - 撮影とカメラの受け渡し（「見て」の撮影と同時にカメラを使わない）

    /// 撮影の前に呼ぶ。見守りのカメラを止め、止まるまで待つ
    func suspendForCapture() async {
        isSuspendedForCapture = true
        endConsentWindow()
        await cameraTask?.value
        guard isWatching else { return }
        await watcher.stop()
        isWatching = false
        trace("見守り: 撮影のあいだカメラを止める")
    }

    /// 撮影のあと（成功しても失敗しても）呼ぶ。少し待ってから見守りのカメラを動かす
    func resumeAfterCapture() {
        guard isSuspendedForCapture else { return }
        isSuspendedForCapture = false
        guard detector != nil else { return }
        detector?.resetBaseline(at: clock.now)
        startCamera(after: Self.resumeDelay)
    }

    // MARK: - 内部

    private func startCamera(after delay: Duration? = nil) {
        let previous = cameraTask
        cameraTask = Task { [weak self] in
            await previous?.value
            if let delay { try? await Task.sleep(for: delay) }
            guard let self, self.detector != nil, !self.isSuspendedForCapture, !self.isWatching else { return }
            do {
                try await self.watcher.start()
                // 動かしている間にセッションが終わった・撮影が始まった
                guard self.detector != nil, !self.isSuspendedForCapture else {
                    await self.watcher.stop()
                    return
                }
                self.isWatching = true
                self.detector?.resetBaseline(at: self.clock.now)
                self.trace("見守り: カメラを動かした（映像は端末の外に出さず、保存もしない）")
            } catch {
                self.trace("見守り: カメラを使えない（\(error.localizedDescription)）")
            }
        }
    }

    /// 読み取った 1 回分を StallDetector に通す
    func handle(_ sample: ActivitySample) {
        guard isWatching, !isSuspendedForCapture, var detector, let host else { return }
        let now = clock.now
        let quiet = host.watchOverIsQuiet
        if !quiet { lastBusyAt = now }
        let events = detector.observe(.init(
            at: now, facePresent: sample.facePresent, handsVisible: sample.handsVisible, moving: sample.isMoving,
            conversationBusy: !quiet, focusing: host.watchOverIsFocusing
        ))
        self.detector = detector
        logSummary(sample)
        for event in events { handle(event) }
    }

    private func handle(_ event: WatchEvent) {
        guard let host else { return }
        switch event {
        case .stalled(let minutes):
            trace("見守り: 手が \(Self.format(minutes)) 分止まっている")
            if let deadline = consentDeadline, clock.now > deadline { endConsentWindow() }
            guard checkInTask == nil, consentDeadline == nil else { return }
            checkInTask = Task { [weak self] in
                await self?.checkIn(minutes: minutes)
                self?.checkInTask = nil
            }
        case .away:
            pausedTimer = host.watchOverPauseTimer() || pausedTimer
            trace("見守り: 席を立ったみたい（\(pausedTimer ? "タイマーを止めた" : "タイマーは止まっていた")）")
        case .returned:
            trace("見守り: 席に戻った\(pausedTimer ? "（タイマーを動かす）" : "")")
            if pausedTimer {
                pausedTimer = false
                host.watchOverResumeTimer()
            }
        }
    }

    /// 声をかけるか判断して、かけるなら「どこか考え中？ちょっと見せて？」
    private func checkIn(minutes: Double) async {
        guard let host, let judge, host.watchOverIsQuiet, host.watchOverIsFocusing else { return }
        let sinceBusy = lastBusyAt.map { (clock.now - $0) / .seconds(60) }
        let context = NudgeContext(
            minutesStalled: minutes, phase: .working, minutesSinceTeacherSpoke: sinceBusy, isFacePresent: true
        )
        let speak = await judge.shouldSpeakUp(context)
        trace("見守り: 声をかけるか → \(speak ? "かける" : "見守る")")
        // 判断を待つ間に、話し始めた・撮影が始まった・終わった・席を立ったなら声をかけない（あとから言い直さない）
        guard speak, !Task.isCancelled, let host = self.host, detector?.isAway == false, !isSuspendedForCapture,
              host.watchOverIsQuiet, host.watchOverIsFocusing
        else { return }
        guard await host.watchOverCheckIn(Self.checkInLines) else {
            trace("見守り: 声をかける前に子どもが話し始めた")
            return
        }
        guard self.host != nil else { return }
        consentDeadline = clock.now + Self.consentWindow
        isAwaitingConsent = true
        consentExpiry = clock.schedule(after: Self.consentWindow) { [weak self] in
            guard let self, self.isAwaitingConsent else { return }
            self.trace("見守り: 声かけに返事がなかった（また見守る）")
            self.endConsentWindow()
        }
    }

    private func endConsentWindow() {
        consentExpiry?.cancel()
        consentExpiry = nil
        consentDeadline = nil
        isAwaitingConsent = false
    }

    /// 実機でしきい値を合わせるため、1 分ごとに読み取りの様子を記録する（映像は残さない）
    private func logSummary(_ sample: ActivitySample) {
        sampleCount += 1
        if sample.isMoving { movingCount += 1 }
        guard sampleCount >= 120 else { return }
        let hand = sample.handMotion.map { String(format: "%.3f", $0) } ?? "-"
        trace("見守り: 直近 \(sampleCount) 回のうち動いた \(movingCount) 回（最後: 顔 \(sample.facePresent ? "あり" : "なし")・手 \(sample.handsVisible ? "あり" : "なし")・差分 \(String(format: "%.3f", sample.frameMotion))・手の移動 \(hand)）")
        sampleCount = 0
        movingCount = 0
    }

    private func trace(_ message: String) {
        if let host {
            host.watchOverTrace(message)
        } else {
            logger.info("\(message, privacy: .public)")
        }
    }

    private static func format(_ minutes: Double) -> String {
        String(format: "%.1f", minutes)
    }
}

/// 「ちょっと見せて？」への返事が、見せてよいという意味か（規則ベース）。断りの言い方を先に見る
enum ConsentDetector {
    static let declines = [
        "だいじょうぶ", "大丈夫", "いらない", "あとで", "後で", "じぶんで", "自分で", "へいき", "平気",
        "やだ", "いやだ", "だめ", "ダメ", "ううん", "いいえ", "けっこう", "結構", "いいです", "見ないで", "みないで",
    ]
    static let agrees = [
        "うん", "いいよ", "はい", "どうぞ", "おねがい", "お願い", "ええよ", "オッケー", "おっけー", "ok",
        "見て", "みて", "見せ", "みせ", "わかんない", "わからない", "分からない", "分かんない", "ほしい",
    ]

    static func isConsent(_ utterance: String) -> Bool {
        let text = DecisionText.normalize(utterance).lowercased()
        guard !text.isEmpty else { return false }
        if declines.contains(where: text.contains) || text.hasPrefix("いや") { return false }
        return agrees.contains(where: text.contains)
    }
}

/// 「見て」の撮影の前後で、見守りのカメラを止めて戻す（AVCaptureSession は同時に 1 つだけ動かす）
@MainActor
final class WatchAwarePhotoCapture: PhotoCapturing {
    let base: any PhotoCapturing
    let watchOver: WatchOver

    init(base: any PhotoCapturing, watchOver: WatchOver) {
        self.base = base
        self.watchOver = watchOver
    }

    var isAvailable: Bool { base.isAvailable }

    func prepare(position: CameraPosition) async throws {
        await watchOver.suspendForCapture()
        do {
            try await base.prepare(position: position)
        } catch {
            watchOver.resumeAfterCapture()
            throw error
        }
    }

    func capture() async throws -> UIImage {
        defer { watchOver.resumeAfterCapture() }
        return try await base.capture()
    }
}
