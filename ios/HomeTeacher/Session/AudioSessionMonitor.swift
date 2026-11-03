@preconcurrency import AVFoundation
import OSLog
import UIKit

// MARK: - 出来事

/// 音声まわりで、パイプラインを止めたり作り直したりするきっかけ（#75）
enum AudioSessionEvent: Equatable, Sendable {
    /// 電話・Siri・他のアプリなどで音声が中断された。`wasSuspended` はアプリが裏にいた間の中断が、戻ってから遅れて届いたもの
    case interruptionBegan(wasSuspended: Bool)
    /// 中断が終わった。`shouldResume` が false なら、アプリが前に出てきたときに戻す
    case interruptionEnded(shouldResume: Bool)
    /// 出力・入力の機器が変わった（イヤホンの抜き差しなど）
    case routeChanged(RouteChange)
    /// AVAudioEngine の構成が変わり、エンジンが止められた（`AVAudioEngineConfigurationChange`）
    case engineConfigurationChanged
    /// アプリが前に出てきた
    case appBecameActive

    enum RouteChange: Equatable, Sendable {
        case newDeviceAvailable
        case oldDeviceUnavailable
        case routeConfigurationChange
        /// カテゴリの変更（自分の setCategory でも来る）・上書きなど。作り直さない
        case other
    }

    var isRouteOrConfigurationChange: Bool {
        switch self {
        case .routeChanged(let change): change != .other
        case .engineConfigurationChanged: true
        case .interruptionBegan, .interruptionEnded, .appBecameActive: false
        }
    }

    /// 通知を出来事にする。関係のない通知は nil
    static func parse(name: Notification.Name, userInfo: [AnyHashable: Any]?) -> AudioSessionEvent? {
        switch name {
        case AVAudioSession.interruptionNotification:
            guard let raw = userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return nil }
            switch type {
            case .began:
                let reason = (userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt)
                    .flatMap(AVAudioSession.InterruptionReason.init(rawValue:))
                return .interruptionBegan(wasSuspended: reason == .appWasSuspended)
            case .ended:
                let options = AVAudioSession.InterruptionOptions(
                    rawValue: userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                )
                return .interruptionEnded(shouldResume: options.contains(.shouldResume))
            @unknown default:
                return nil
            }
        case AVAudioSession.routeChangeNotification:
            let reason = (userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            return switch reason {
            case .newDeviceAvailable: .routeChanged(.newDeviceAvailable)
            case .oldDeviceUnavailable: .routeChanged(.oldDeviceUnavailable)
            case .routeConfigurationChange: .routeChanged(.routeConfigurationChange)
            default: .routeChanged(.other)
            }
        case .AVAudioEngineConfigurationChange:
            return .engineConfigurationChanged
        case UIApplication.didBecomeActiveNotification:
            return .appBecameActive
        default:
            return nil
        }
    }
}

/// 出来事の出どころ。本番は NotificationCenter、テストでは手で流す
@MainActor
protocol AudioSessionEventSource: AnyObject {
    var events: AsyncStream<AudioSessionEvent> { get }
}

/// AVAudioSession の通知・エンジンの構成変更・アプリが前に出たことを受け取る
@MainActor
final class NotificationAudioSessionEvents: AudioSessionEventSource {
    let events: AsyncStream<AudioSessionEvent>
    private let center: NotificationCenter
    /// deinit（MainActor の外）で外す。NotificationCenter の removeObserver はどのスレッドからでも呼べる
    nonisolated(unsafe) private let observers: [any NSObjectProtocol]

    /// - Parameter engine: 構成変更を見るエンジン。ほかのエンジン（検証画面など）の変更では作り直さない
    init(engine: AVAudioEngine, center: NotificationCenter = .default) {
        self.center = center
        let (stream, continuation) = AsyncStream.makeStream(of: AudioSessionEvent.self)
        events = stream
        let sources: [(Notification.Name, AnyObject?)] = [
            (AVAudioSession.interruptionNotification, AVAudioSession.sharedInstance()),
            (AVAudioSession.routeChangeNotification, AVAudioSession.sharedInstance()),
            (.AVAudioEngineConfigurationChange, engine),
            (UIApplication.didBecomeActiveNotification, nil),
        ]
        observers = sources.map { name, object in
            // Notification は Sendable ではないので、受け取ったスレッドで出来事にしてから渡す
            center.addObserver(forName: name, object: object, queue: nil) { notification in
                if let event = AudioSessionEvent.parse(name: notification.name, userInfo: notification.userInfo) {
                    continuation.yield(event)
                }
            }
        }
    }

    deinit {
        for observer in observers { center.removeObserver(observer) }
    }
}

// MARK: - つなぐ相手

/// 止めて作り直せる音声（本番はマイク + 先生の声のプレイヤー。テストでは偽物）
@MainActor
protocol AudioRecoveryTarget: AnyObject {
    /// いまエンジンと認識が動いているか（裏に回ったあとなど、通知が来ないままシステムに止められていることがある）
    var isAudioRunning: Bool { get }
    /// エンジンと認識を止める（すぐ返す）
    func suspendAudio()
    /// エンジン（タップ・voice processing・再生ノード）と認識を作り直して動かす
    func rebuildAudio() async throws
}

/// 中断の間、学習セッションを一時停止する相手（本番は StudySessionCoordinator）
@MainActor
protocol AudioInterruptionHandling: AnyObject {
    /// 中断が始まった。作りかけの返事を捨て、タイマーを止める
    func pauseForAudioInterruption() async
    /// 中断から戻った（音声を作り直したあと）。タイマーを動かし、先生が「おかえり」と声をかける
    func resumeAfterAudioInterruption() async
}

// MARK: - 見張り役

/// 音声の中断・機器の切り替え・エンジンの構成変更から立ち直る（#75）。
///
/// - 中断が始まったら音声を止め、セッションを一時停止する。終わったら（`shouldResume` がなければアプリが前に出たときに）作り直して、セッションを再開する
/// - 機器の切り替え・構成変更は、続けて来るもの（イヤホンを抜くと両方来る）を `debounce` でまとめて 1 回だけ作り直す。セッションは止めない
/// - 作り直している間と、作り直した直後（`settleTime`）の切り替えは無視する（自分の setCategory・voice processing の切り替えでも来るため）
/// - 作り直しは `rebuildTimeout` で打ち切り、`retryDelays` の間隔でやり直す。それでもだめなら、次のきっかけ（アプリが前に出たなど）まで止めたまま
/// - 検証画面に音声を貸している間（`yieldAudio()` 〜 `reclaimAudio()`）は何もしない
@MainActor
final class AudioSessionMonitor {
    enum State: Equatable, Sendable {
        case running
        /// 中断中（作り直すのを待っている）
        case interrupted
        /// 作り直しているところ
        case rebuilding
        /// 検証画面などに音声を貸している
        case yielded
        /// 作り直せなかった。次のきっかけを待つ
        case failed
    }

    struct Timing: Sendable {
        var debounce: Duration = .milliseconds(300)
        var settleTime: Duration = .seconds(1)
        var rebuildTimeout: Duration = .seconds(8)
        var retryDelays: [Duration] = [.seconds(1), .seconds(2)]
    }

    private(set) var state: State = .running
    /// 作り直した回数（成功したもの）
    private(set) var recoveredCount = 0
    weak var session: (any AudioInterruptionHandling)?
    /// 状態が変わるたびに呼ぶ（画面の表示用）
    var onStateChange: ((State) -> Void)?

    private let source: any AudioSessionEventSource
    private let target: any AudioRecoveryTarget
    private let clock: any ConversationClock
    private let timing: Timing
    private let logger = Logger(subsystem: "com.kawamataryo.HomeTeacher", category: "AudioSessionMonitor")
    private var listenTask: Task<Void, Never>?
    private var debounceAction: (any ScheduledAction)?
    /// 止めるたびに増やす。作り直しの途中で中断が来たら、その作り直しの結果は使わない
    private var epoch = 0
    private var settledAt: ContinuousClock.Instant?
    /// 中断でセッションを一時停止したか（戻ったときに 1 回だけ再開する）
    private var pausedSession = false
    /// 作り直しの途中で来た頼みごと。作り直しが終わったら、こちらに移る
    private var afterRebuild: AfterRebuild?

    private enum AfterRebuild: Equatable {
        /// 中断が来た。`resume` は、その中断がもう終わったか
        case interrupted(resume: Bool)
        /// 検証画面に貸す
        case yielded
        /// 貸して、もう返してもらった（作り直し直す）
        case rebuildAgain
    }

    init(source: any AudioSessionEventSource, target: any AudioRecoveryTarget, clock: any ConversationClock, timing: Timing = Timing()) {
        self.source = source
        self.target = target
        self.clock = clock
        self.timing = timing
    }

    /// 出来事を読み始める
    func start() {
        guard listenTask == nil else { return }
        let stream = source.events
        listenTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    func stop() {
        listenTask?.cancel()
        listenTask = nil
        debounceAction?.cancel()
        debounceAction = nil
    }

    func handle(_ event: AudioSessionEvent) {
        logger.info("音声の出来事: \(String(describing: event), privacy: .public)（状態: \(String(describing: self.state), privacy: .public)）")
        switch event {
        case .interruptionBegan(let wasSuspended):
            // 裏にいた間の中断が戻ってから遅れて届いたもの。もう終わっているので一時停止はせず、止まっていれば作り直す
            guard !wasSuspended else { recoverIfStopped(); return }
            beginInterruption()
        case .interruptionEnded(let shouldResume):
            guard shouldResume else { return }
            resumeFromInterruption()
        case .appBecameActive:
            switch state {
            case .failed: recover()
            // 他のアプリから戻った。終わりの通知が来ないまま、エンジンが止められていることがある
            case .running: recoverIfStopped()
            case .interrupted, .rebuilding, .yielded: resumeFromInterruption()
            }
        case .routeChanged, .engineConfigurationChanged:
            guard event.isRouteOrConfigurationChange, state == .running else { return }
            if let settledAt, clock.now - settledAt < timing.settleTime { return }
            debounceAction?.cancel()
            debounceAction = clock.schedule(after: timing.debounce) { [weak self] in
                guard let self, self.state == .running else { return }
                self.debounceAction = nil
                self.recover()
            }
        }
    }

    /// 検証画面などに音声を貸す。止めて、返されるまで何もしない
    func yieldAudio() {
        debounceAction?.cancel()
        debounceAction = nil
        switch state {
        case .yielded:
            return
        case .rebuilding:
            afterRebuild = .yielded
        case .running, .interrupted, .failed:
            setState(.yielded)
        }
        epoch += 1
        target.suspendAudio()
    }

    /// 貸していた音声を返してもらい、作り直す
    func reclaimAudio() {
        if state == .rebuilding, afterRebuild == .yielded {
            afterRebuild = .rebuildAgain
            return
        }
        guard state == .yielded else { return }
        recover()
    }

    // MARK: - 内部

    private func beginInterruption() {
        debounceAction?.cancel()
        debounceAction = nil
        switch state {
        case .interrupted, .yielded:
            return
        case .rebuilding:
            // 貸し出し・中断を頼まれているなら、そちらが先
            if afterRebuild == .yielded { return }
            if case .interrupted = afterRebuild { return }
            afterRebuild = .interrupted(resume: false)
        case .running, .failed:
            setState(.interrupted)
        }
        epoch += 1
        target.suspendAudio()
        if !pausedSession, let session {
            pausedSession = true
            Task { await session.pauseForAudioInterruption() }
        }
    }

    /// 動いているはずなのにエンジンが止まっていたら、黙って作り直す（セッションは止めない）
    private func recoverIfStopped() {
        guard state == .running, !target.isAudioRunning else { return }
        logger.info("エンジンが止められていたので作り直す")
        recover()
    }

    private func resumeFromInterruption() {
        if state == .interrupted {
            recover()
        } else if state == .rebuilding, afterRebuild == .interrupted(resume: false) {
            afterRebuild = .interrupted(resume: true)
        }
    }

    private func recover() {
        guard state != .rebuilding else { return }
        epoch += 1
        let current = epoch
        afterRebuild = nil
        setState(.rebuilding)
        Task { [weak self] in
            guard let self else { return }
            let succeeded = await self.rebuildWithRetries(epoch: current)
            await self.finishRecovery(succeeded: succeeded, epoch: current)
        }
    }

    private func rebuildWithRetries(epoch: Int) async -> Bool {
        let attempts = timing.retryDelays.count + 1
        for attempt in 0..<attempts {
            guard epoch == self.epoch else { return false }
            if attempt > 0 {
                await sleep(timing.retryDelays[attempt - 1])
                guard epoch == self.epoch else { return false }
            }
            do {
                try await withTimeout(timing.rebuildTimeout) { [target] in try await target.rebuildAudio() }
                return true
            } catch {
                logger.error("音声を作り直せなかった（\(attempt + 1)/\(attempts) 回目）: \(String(describing: error), privacy: .public)")
                // 途中まで動いたものを止めてからやり直す
                target.suspendAudio()
            }
        }
        return false
    }

    private func finishRecovery(succeeded: Bool, epoch current: Int) async {
        guard current == epoch else {
            // 作り直している間に中断・貸し出しが来た。動かしたものを止めて、そちらに移る
            target.suspendAudio()
            let next = afterRebuild
            afterRebuild = nil
            switch next {
            case .yielded:
                setState(.yielded)
            case .interrupted(let resume):
                setState(.interrupted)
                if resume { recover() }
            case .rebuildAgain, nil:
                setState(.failed)
                recover()
            }
            return
        }
        guard succeeded else {
            setState(.failed)
            return
        }
        recoveredCount += 1
        settledAt = clock.now
        setState(.running)
        logger.info("音声を作り直した（\(self.recoveredCount) 回目）")
        if pausedSession {
            pausedSession = false
            await session?.resumeAfterAudioInterruption()
        }
    }

    private func setState(_ next: State) {
        guard state != next else { return }
        state = next
        onStateChange?(next)
    }

    private func sleep(_ duration: Duration) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            _ = clock.schedule(after: duration) { continuation.resume() }
        }
    }

    struct TimeoutError: Error {}

    /// `operation` を `duration` で打ち切る（実機では認識エンジンの開始・停止が返ってこないことがある）。
    /// 打ち切ったあとも `operation` は後ろで走り続けるので、呼び出し側で止めること
    private func withTimeout(_ duration: Duration, _ operation: @escaping @MainActor @Sendable () async throws -> Void) async throws {
        let once = OnceFlag()
        var timeout: (any ScheduledAction)?
        defer { timeout?.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            timeout = clock.schedule(after: duration) {
                if once.take() { continuation.resume(throwing: TimeoutError()) }
            }
            Task { @MainActor in
                do {
                    try await operation()
                    if once.take() { continuation.resume() }
                } catch {
                    if once.take() { continuation.resume(throwing: error) }
                }
            }
        }
    }
}

// MARK: - 本番の相手

extension StudySessionCoordinator: AudioInterruptionHandling {}

/// 学習セッションのマイク（`MicrophoneSpeechInput`）と先生の声（`EngineClipPlayer`）を、同じエンジンで止めて作り直す。
/// 順番は #9 / #13 の実機検証と同じ（エンジンと認識を動かしてから、再生ノードをつなぐ）
@MainActor
final class SessionAudioRecovery: AudioRecoveryTarget {
    let microphone: MicrophoneSpeechInput
    let player: EngineClipPlayer
    /// 作り直せたら呼ぶ（画面の表示用）
    var onRebuilt: ((RecognizerKind) -> Void)?

    init(microphone: MicrophoneSpeechInput, player: EngineClipPlayer) {
        self.microphone = microphone
        self.player = player
    }

    func suspendAudio() {
        player.suspend()
        microphone.suspend()
    }

    var isAudioRunning: Bool { microphone.isRunning && microphone.engine.isRunning }

    func rebuildAudio() async throws {
        // エンジンを止めてから再生ノードを外す
        microphone.suspend()
        player.detach()
        let kind = try await microphone.resume()
        player.reattach()
        onRebuilt?(kind)
    }
}
