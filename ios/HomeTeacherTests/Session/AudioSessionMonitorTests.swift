@preconcurrency import AVFoundation
import Foundation
import Testing
import UIKit
@testable import HomeTeacher

// MARK: - テスト用の偽物

/// 出来事を手で流す
@MainActor
final class FakeAudioSessionEvents: AudioSessionEventSource {
    let events: AsyncStream<AudioSessionEvent>
    private let continuation: AsyncStream<AudioSessionEvent>.Continuation

    init() {
        (events, continuation) = AsyncStream.makeStream(of: AudioSessionEvent.self)
    }

    func send(_ event: AudioSessionEvent) { continuation.yield(event) }
}

/// 止めた・作り直した回数を数える偽のパイプライン。`failures` 回だけ作り直しに失敗する。`holdsRebuild` なら `finishRebuild()` まで返さない
@MainActor
final class FakeAudioPipeline: AudioRecoveryTarget {
    struct Failure: Error {}

    private(set) var suspendCount = 0
    private(set) var rebuildCount = 0
    private(set) var isRunning = true
    var isAudioRunning: Bool { isRunning }

    /// 通知なしでシステムにエンジンを止められた（他のアプリから戻ったときなど）
    func stopBySystem() { isRunning = false }
    var failures = 0
    var holdsRebuild = false
    private var held: CheckedContinuation<Void, Never>?

    func suspendAudio() {
        suspendCount += 1
        isRunning = false
    }

    func rebuildAudio() async throws {
        rebuildCount += 1
        if holdsRebuild { await withCheckedContinuation { held = $0 } }
        if failures > 0 {
            failures -= 1
            throw Failure()
        }
        isRunning = true
    }

    var isHoldingRebuild: Bool { held != nil }

    func finishRebuild() {
        held?.resume()
        held = nil
    }
}

@MainActor
final class FakeInterruptedSession: AudioInterruptionHandling {
    private(set) var log: [String] = []

    func pauseForAudioInterruption() async { log.append("pause") }
    func resumeAfterAudioInterruption() async { log.append("resume") }
}

@MainActor
final class FakeLeaseHolder: AudioEngineLeaseHolder {
    private(set) var revokedCount = 0
    func audioLeaseRevoked() { revokedCount += 1 }
}

@MainActor
private final class MonitorHarness {
    let source = FakeAudioSessionEvents()
    let pipeline = FakeAudioPipeline()
    let session = FakeInterruptedSession()
    let clock = ManualClock()
    let monitor: AudioSessionMonitor

    init() {
        monitor = AudioSessionMonitor(source: source, target: pipeline, clock: clock)
        monitor.session = session
        monitor.start()
    }

    /// 出来事を流して、読み取りのタスクに処理させる
    func send(_ event: AudioSessionEvent) async {
        source.send(event)
        await settle()
    }

    func settle() async {
        for _ in 0..<30 { await Task.yield() }
    }
}

// MARK: - 見張り役

/// 音声の中断・機器の切り替えから立ち直る（#75）。通知は偽物で流し、パイプラインも偽物で数える
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct AudioSessionMonitorTests {
    @Test func 中断が始まると止めてセッションを一時停止し終わったら作り直して再開する() async {
        let h = MonitorHarness()
        await h.send(.interruptionBegan(wasSuspended: false))
        #expect(h.monitor.state == .interrupted)
        #expect(h.pipeline.suspendCount == 1)
        #expect(h.pipeline.isRunning == false)
        #expect(await eventually { h.session.log == ["pause"] })

        await h.send(.interruptionEnded(shouldResume: true))
        #expect(await eventually { h.monitor.state == .running })
        #expect(h.pipeline.rebuildCount == 1)
        #expect(h.pipeline.isRunning)
        #expect(await eventually { h.session.log == ["pause", "resume"] })
    }

    @Test func 再開してよいと言われなければアプリが前に出るまで待つ() async {
        let h = MonitorHarness()
        await h.send(.interruptionBegan(wasSuspended: false))
        await h.send(.interruptionEnded(shouldResume: false))
        #expect(h.monitor.state == .interrupted)
        #expect(h.pipeline.rebuildCount == 0)

        await h.send(.appBecameActive)
        #expect(await eventually { h.monitor.state == .running })
        #expect(h.pipeline.rebuildCount == 1)
        #expect(await eventually { h.session.log == ["pause", "resume"] })
    }

    @Test func 終わりの通知が来なくてもアプリが前に出たら戻る() async {
        let h = MonitorHarness()
        await h.send(.interruptionBegan(wasSuspended: false))
        await h.send(.appBecameActive)
        #expect(await eventually { h.monitor.state == .running })
        #expect(h.pipeline.rebuildCount == 1)
    }

    @Test func 中断が重なっても止めるのも再開するのも1回() async {
        let h = MonitorHarness()
        await h.send(.interruptionBegan(wasSuspended: false))
        await h.send(.interruptionBegan(wasSuspended: false))
        #expect(h.pipeline.suspendCount == 1)
        #expect(await eventually { h.session.log == ["pause"] })

        await h.send(.interruptionEnded(shouldResume: true))
        #expect(await eventually { h.monitor.state == .running })
        // もう動いているので、遅れて来た終わりの通知では作り直さない
        await h.send(.interruptionEnded(shouldResume: true))
        await h.send(.appBecameActive)
        #expect(h.pipeline.rebuildCount == 1)
        #expect(await eventually { h.session.log == ["pause", "resume"] })
    }

    @Test func 裏にいた間の中断が遅れて届いても動いていれば何もしない() async {
        let h = MonitorHarness()
        await h.send(.interruptionBegan(wasSuspended: true))
        await h.send(.appBecameActive)
        #expect(h.monitor.state == .running)
        #expect(h.pipeline.suspendCount == 0)
        #expect(h.pipeline.rebuildCount == 0)
        #expect(h.session.log.isEmpty)
    }

    @Test func 他のアプリから戻ってエンジンが止まっていたら黙って作り直す() async {
        let h = MonitorHarness()
        h.pipeline.stopBySystem()
        await h.send(.interruptionBegan(wasSuspended: true))
        await h.send(.appBecameActive)
        #expect(await eventually { h.monitor.state == .running })
        #expect(h.pipeline.rebuildCount == 1)
        #expect(h.pipeline.isRunning)
        // 一時停止も「おかえり」もしない
        await h.settle()
        #expect(h.session.log.isEmpty)
    }

    @Test func 中断していないのに終わりの通知が来ても何もしない() async {
        let h = MonitorHarness()
        await h.send(.interruptionEnded(shouldResume: true))
        await h.send(.appBecameActive)
        #expect(h.monitor.state == .running)
        #expect(h.pipeline.rebuildCount == 0)
    }

    @Test func イヤホンの抜き差しと構成変更が続けて来ても作り直すのは1回でセッションは止めない() async {
        let h = MonitorHarness()
        await h.send(.routeChanged(.oldDeviceUnavailable))
        await h.send(.engineConfigurationChanged)
        await h.send(.routeChanged(.newDeviceAvailable))
        #expect(h.pipeline.rebuildCount == 0)

        h.clock.advance(by: .milliseconds(300))
        #expect(await eventually { h.monitor.state == .running && h.pipeline.rebuildCount == 1 })
        await h.settle()
        #expect(h.pipeline.rebuildCount == 1)
        #expect(h.session.log.isEmpty)
    }

    @Test func カテゴリの変更では作り直さない() async {
        let h = MonitorHarness()
        // 自分の setCategory でも来る。作り直すと setCategory → 作り直し… と繰り返してしまう
        await h.send(.routeChanged(.other))
        h.clock.advance(by: .seconds(1))
        await h.settle()
        #expect(h.pipeline.rebuildCount == 0)
    }

    @Test func 作り直している間と直後の構成変更は無視する() async {
        let h = MonitorHarness()
        h.pipeline.holdsRebuild = true
        await h.send(.engineConfigurationChanged)
        h.clock.advance(by: .milliseconds(300))
        #expect(await eventually { h.pipeline.isHoldingRebuild })
        #expect(h.monitor.state == .rebuilding)

        // voice processing を入れ直すと自分で構成変更を起こす
        await h.send(.engineConfigurationChanged)
        h.pipeline.finishRebuild()
        #expect(await eventually { h.monitor.state == .running })
        await h.send(.engineConfigurationChanged)
        h.clock.advance(by: .milliseconds(500))
        await h.settle()
        #expect(h.pipeline.rebuildCount == 1)

        // 落ち着いたあとの切り替えでは、また作り直す
        h.clock.advance(by: .seconds(1))
        await h.send(.routeChanged(.newDeviceAvailable))
        h.clock.advance(by: .milliseconds(300))
        #expect(await eventually { h.pipeline.rebuildCount == 2 })
    }

    @Test func 中断中の機器の切り替えでは作り直さず終わってから1回だけ作り直す() async {
        let h = MonitorHarness()
        await h.send(.interruptionBegan(wasSuspended: false))
        await h.send(.routeChanged(.newDeviceAvailable))
        h.clock.advance(by: .seconds(1))
        await h.settle()
        #expect(h.pipeline.rebuildCount == 0)

        await h.send(.interruptionEnded(shouldResume: true))
        #expect(await eventually { h.monitor.state == .running })
        #expect(h.pipeline.rebuildCount == 1)
    }

    @Test func 作り直しに失敗したら間をあけてやり直す() async {
        let h = MonitorHarness()
        h.pipeline.failures = 1
        await h.send(.interruptionBegan(wasSuspended: false))
        await h.send(.interruptionEnded(shouldResume: true))
        #expect(await eventually { h.pipeline.rebuildCount == 1 })
        #expect(h.monitor.state == .rebuilding)

        h.clock.advance(by: .seconds(1))
        #expect(await eventually { h.monitor.state == .running })
        #expect(h.pipeline.rebuildCount == 2)
        #expect(await eventually { h.session.log == ["pause", "resume"] })
    }

    @Test func 何度やっても作り直せなければ止めたまま次のきっかけを待つ() async {
        let h = MonitorHarness()
        h.pipeline.failures = 10
        await h.send(.interruptionBegan(wasSuspended: false))
        await h.send(.interruptionEnded(shouldResume: true))
        #expect(await eventually { h.pipeline.rebuildCount == 1 })
        h.clock.advance(by: .seconds(1))
        #expect(await eventually { h.pipeline.rebuildCount == 2 })
        h.clock.advance(by: .seconds(2))
        #expect(await eventually { h.monitor.state == .failed })
        #expect(h.pipeline.rebuildCount == 3)
        // 再開しない（先生は「おかえり」と言わない）
        #expect(await eventually { h.session.log == ["pause"] })

        h.clock.advance(by: .seconds(10))
        await h.settle()
        #expect(h.pipeline.rebuildCount == 3)

        h.pipeline.failures = 0
        await h.send(.appBecameActive)
        #expect(await eventually { h.monitor.state == .running })
        #expect(await eventually { h.session.log == ["pause", "resume"] })
    }

    @Test func 作り直しが返ってこなければ打ち切ってやり直す() async {
        let h = MonitorHarness()
        h.pipeline.holdsRebuild = true
        await h.send(.engineConfigurationChanged)
        h.clock.advance(by: .milliseconds(300))
        #expect(await eventually { h.pipeline.isHoldingRebuild })

        // 8 秒で打ち切り、止めてから 1 秒あけてやり直す
        let suspendsBefore = h.pipeline.suspendCount
        h.clock.advance(by: .seconds(8))
        #expect(await eventually { h.pipeline.suspendCount == suspendsBefore + 1 })
        h.pipeline.holdsRebuild = false
        h.pipeline.finishRebuild()
        h.clock.advance(by: .seconds(1))
        #expect(await eventually { h.monitor.state == .running })
        #expect(h.pipeline.rebuildCount == 2)
    }

    @Test func 作り直している途中に中断が来たらその結果は使わない() async {
        let h = MonitorHarness()
        h.pipeline.holdsRebuild = true
        await h.send(.engineConfigurationChanged)
        h.clock.advance(by: .milliseconds(300))
        #expect(await eventually { h.pipeline.isHoldingRebuild })

        await h.send(.interruptionBegan(wasSuspended: false))
        #expect(await eventually { h.session.log == ["pause"] })
        h.pipeline.holdsRebuild = false
        h.pipeline.finishRebuild()
        #expect(await eventually { h.monitor.state == .interrupted })
        #expect(h.pipeline.isRunning == false)

        await h.send(.interruptionEnded(shouldResume: true))
        #expect(await eventually { h.monitor.state == .running })
        #expect(h.pipeline.rebuildCount == 2)
        #expect(await eventually { h.session.log == ["pause", "resume"] })
    }

    @Test func 貸している間は何もせず返してもらったら作り直す() async {
        let h = MonitorHarness()
        h.monitor.yieldAudio()
        #expect(h.monitor.state == .yielded)
        #expect(h.pipeline.suspendCount == 1)

        // 検証画面のエンジンの中断・切り替えでは動かない
        await h.send(.interruptionBegan(wasSuspended: false))
        await h.send(.routeChanged(.newDeviceAvailable))
        await h.send(.appBecameActive)
        h.clock.advance(by: .seconds(1))
        await h.settle()
        #expect(h.pipeline.rebuildCount == 0)
        #expect(h.session.log.isEmpty)

        h.monitor.reclaimAudio()
        #expect(await eventually { h.monitor.state == .running })
        #expect(h.pipeline.rebuildCount == 1)
        // 貸し借りでは「おかえり」と言わない
        await h.settle()
        #expect(h.session.log.isEmpty)
    }
}

// MARK: - 通知の読み取り

struct AudioSessionEventParseTests {
    @Test func 中断の始まりと終わりを読む() {
        let began = AudioSessionEvent.parse(
            name: AVAudioSession.interruptionNotification,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
        )
        #expect(began == .interruptionBegan(wasSuspended: false))

        let suspended = AudioSessionEvent.parse(
            name: AVAudioSession.interruptionNotification,
            userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue,
                AVAudioSessionInterruptionReasonKey: AVAudioSession.InterruptionReason.appWasSuspended.rawValue,
            ]
        )
        #expect(suspended == .interruptionBegan(wasSuspended: true))

        let resume = AudioSessionEvent.parse(
            name: AVAudioSession.interruptionNotification,
            userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue,
            ]
        )
        #expect(resume == .interruptionEnded(shouldResume: true))

        let noResume = AudioSessionEvent.parse(
            name: AVAudioSession.interruptionNotification,
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue]
        )
        #expect(noResume == .interruptionEnded(shouldResume: false))
        #expect(AudioSessionEvent.parse(name: AVAudioSession.interruptionNotification, userInfo: nil) == nil)
    }

    @Test func 機器の切り替えの理由を分ける() {
        func parse(_ reason: AVAudioSession.RouteChangeReason) -> AudioSessionEvent? {
            AudioSessionEvent.parse(name: AVAudioSession.routeChangeNotification, userInfo: [AVAudioSessionRouteChangeReasonKey: reason.rawValue])
        }
        #expect(parse(.newDeviceAvailable) == .routeChanged(.newDeviceAvailable))
        #expect(parse(.oldDeviceUnavailable) == .routeChanged(.oldDeviceUnavailable))
        #expect(parse(.routeConfigurationChange) == .routeChanged(.routeConfigurationChange))
        #expect(parse(.categoryChange) == .routeChanged(.other))
        #expect(parse(.override) == .routeChanged(.other))
        #expect(parse(.categoryChange)?.isRouteOrConfigurationChange == false)
        #expect(parse(.oldDeviceUnavailable)?.isRouteOrConfigurationChange == true)
    }

    @Test func エンジンの構成変更とアプリが前に出たことを読む() {
        #expect(AudioSessionEvent.parse(name: .AVAudioEngineConfigurationChange, userInfo: nil) == .engineConfigurationChanged)
        #expect(AudioSessionEvent.parse(name: UIApplication.didBecomeActiveNotification, userInfo: nil) == .appBecameActive)
        #expect(AudioSessionEvent.parse(name: UIApplication.willResignActiveNotification, userInfo: nil) == nil)
    }

    @Test @MainActor func 通知センターから見張っているエンジンの構成変更だけ受け取る() async {
        let center = NotificationCenter()
        let engine = AVAudioEngine()
        let other = AVAudioEngine()
        let source = NotificationAudioSessionEvents(engine: engine, center: center)
        center.post(name: .AVAudioEngineConfigurationChange, object: other)
        center.post(name: .AVAudioEngineConfigurationChange, object: engine)
        center.post(
            name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
        )
        var received: [AudioSessionEvent] = []
        for await event in source.events {
            received.append(event)
            if received.count == 2 { break }
        }
        #expect(received == [.engineConfigurationChanged, .interruptionBegan(wasSuspended: false)])
    }
}

// MARK: - ミュートの理由・エンジンの持ち主

struct MicrophoneMuteStateTests {
    @Test func 中断中は先生が話し終わってもミュートのまま() {
        var mute = MicrophoneMuteState()
        #expect(mute.isMuted == false)
        mute.requested = true
        mute.suspended = true
        // 中断の間に、ConversationController が話し終わってミュートを外した
        mute.requested = false
        #expect(mute.isMuted)
        mute.suspended = false
        #expect(mute.isMuted == false)
    }

    @Test func 中断が明けても先生が話している間はミュートのまま() {
        var mute = MicrophoneMuteState(requested: true, suspended: true)
        mute.suspended = false
        #expect(mute.isMuted)
    }
}

@MainActor
struct AudioEngineLeaseTests {
    @Test func 借りるといまの持ち主に止めてもらう() {
        let lease = AudioEngineLease()
        let session = FakeLeaseHolder()
        let spike = FakeLeaseHolder()
        lease.acquire(session)
        lease.acquire(session)
        #expect(session.revokedCount == 0)

        lease.acquire(spike)
        #expect(session.revokedCount == 1)
        #expect(lease.isHeld(by: spike))

        // 持ち主でなければ返しても外れない
        lease.release(session)
        #expect(lease.isHeld(by: spike))
        lease.release(spike)
        #expect(lease.currentHolder == nil)

        lease.acquire(session)
        #expect(spike.revokedCount == 0)
    }

    @Test func 検証画面が借りるとセッションの見張り役は止まり返してもらうと作り直す() async {
        let lease = AudioEngineLease()
        let h = MonitorHarness()
        let session = MonitorLeaseHolder(monitor: h.monitor)
        let spike = FakeLeaseHolder()
        lease.acquire(session)

        lease.acquire(spike)
        #expect(h.monitor.state == .yielded)
        #expect(h.pipeline.isRunning == false)

        // 開発用メニューを閉じた（検証画面が止めきる前でも、借り直せば止めてもらえる）
        lease.acquire(session)
        #expect(spike.revokedCount == 1)
        h.monitor.reclaimAudio()
        #expect(await eventually { h.monitor.state == .running })
        #expect(h.pipeline.isRunning)
    }
}

/// SessionAppModel と同じつなぎ方（取り上げられたら見張り役に貸す）
@MainActor
private final class MonitorLeaseHolder: AudioEngineLeaseHolder {
    let monitor: AudioSessionMonitor
    init(monitor: AudioSessionMonitor) { self.monitor = monitor }
    func audioLeaseRevoked() { monitor.yieldAudio() }
}

// MARK: - 学習セッションの一時停止

@MainActor
struct StudySessionAudioInterruptionTests {
    @Test func 中断中はタイマーを止め戻ったら先生がおかえりと言う() async throws {
        let h = try SessionHarness()
        await h.enqueueReply(["こんにちは！"])
        await h.coordinator.start()
        #expect(await eventually { h.coordinator.completedReplies >= 1 && h.coordinator.conversationState == .idle })

        let monitorHarness = MonitorHarness()
        monitorHarness.monitor.session = h.coordinator
        await monitorHarness.send(.interruptionBegan(wasSuspended: false))
        #expect(await eventually { h.coordinator.timer?.status == .paused })

        await monitorHarness.send(.interruptionEnded(shouldResume: true))
        #expect(await eventually { h.voice.spoken.last == StudySessionCoordinator.welcomeBackLine })
        #expect(h.coordinator.timer?.status == .running)
        #expect(await eventually { h.coordinator.conversationState == .idle })
    }

    @Test func 話している途中で中断されたら残りの文は話さない() async throws {
        let h = try SessionHarness()
        await h.enqueueReply(["こんにちは！"])
        await h.coordinator.start()
        #expect(await eventually { h.coordinator.completedReplies >= 1 && h.coordinator.conversationState == .idle })
        h.voice.holdsPlayback = true
        await h.enqueueReply(["まず問題を読もう。", "何を聞かれてるかな？"])
        await h.say("ねえ先生、これわかんない")
        #expect(await eventually { h.voice.spoken.count == 2 })

        h.voice.holdsPlayback = false
        await h.coordinator.pauseForAudioInterruption()
        #expect(await eventually { h.coordinator.conversationState == .idle })
        #expect(!h.voice.spoken.contains("何を聞かれてるかな？"))

        await h.coordinator.resumeAfterAudioInterruption()
        #expect(h.voice.spoken.last == StudySessionCoordinator.welcomeBackLine)
    }

    @Test func セッションの外で中断されても声はかけない() async throws {
        let h = try SessionHarness()
        await h.coordinator.pauseForAudioInterruption()
        await h.coordinator.resumeAfterAudioInterruption()
        #expect(h.voice.spoken.isEmpty)
        #expect(h.coordinator.phase == .idle)
    }
}
