import Foundation
import Testing
import UIKit
@testable import HomeTeacher

/// 見守りのカメラのモック。読み取った値はテストから流す
@MainActor
final class MockActivityWatcher: ActivityWatching {
    var onSample: (@MainActor (ActivitySample) -> Void)?
    var fails = false
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var isRunning = false

    func start() async throws {
        startCount += 1
        if fails { throw CameraError.unauthorized }
        isRunning = true
    }

    func stop() async {
        stopCount += 1
        isRunning = false
    }

    func emit(_ sample: ActivitySample) {
        onSample?(sample)
    }
}

/// 答えを決めておける「声をかけるか」。`holds` のときは `release()` まで答えない
@MainActor
final class StubNudgeJudge: NudgeJudging {
    var answer = true
    var holds = false
    private(set) var contexts: [NudgeContext] = []
    private var waiting: CheckedContinuation<Void, Never>?

    func shouldSpeakUp(_ context: NudgeContext) async -> Bool {
        contexts.append(context)
        if holds { await withCheckedContinuation { waiting = $0 } }
        return answer
    }

    func release() {
        waiting?.resume()
        waiting = nil
    }
}

/// 見守り → 声かけ → 同意 → 撮影、席を立つ → タイマー、をまとめ役を通して確かめる（#30）
@MainActor
struct WatchOverFlowTests {
    static let still = ActivitySample(facePresent: true, handsVisible: true, frameMotion: 0, handMotion: 0)
    static let moving = ActivitySample(facePresent: true, handsVisible: true, frameMotion: 0.2, handMotion: 0.1)
    static let empty = ActivitySample(facePresent: false, handsVisible: false, frameMotion: 0, handMotion: nil)

    @MainActor
    final class Rig {
        let watcher: MockActivityWatcher
        let clock: ManualClock
        let watchOver: WatchOver
        let camera: MockCamera
        let h: SessionHarness

        init(
            configuration: StallDetector.Configuration? = .minutes(3),
            judge: (any NudgeJudging)? = nil
        ) throws {
            let watcher = MockActivityWatcher()
            let clock = ManualClock()
            let camera = MockCamera()
            let watchOver = WatchOver(
                watcher: watcher, clock: clock, configuration: { configuration },
                makeJudge: { config in judge ?? RuleNudgeJudge(stalledMinutesThreshold: config.stallMinutes) }
            )
            self.watcher = watcher
            self.clock = clock
            self.camera = camera
            self.watchOver = watchOver
            h = try SessionHarness(
                camera: WatchAwarePhotoCapture(base: camera, watchOver: watchOver), clock: clock, watchOver: watchOver
            )
        }

        func startSession() async {
            await h.enqueueReply(["こんにちは！"])
            await h.coordinator.start()
            _ = await eventually { self.h.coordinator.completedReplies >= 1 && self.h.coordinator.conversationState == .idle }
        }

        /// `seconds` 秒の間、1 秒ごとに同じ見え方を流す
        func feed(_ sample: ActivitySample, seconds: Int) async {
            for _ in 0..<seconds {
                clock.advance(by: .seconds(1))
                watcher.emit(sample)
                await Task.yield()
            }
        }
    }

    @Test func 手が止まったら声をかけ同意したら撮影する() async throws {
        let rig = try Rig()
        await rig.startSession()
        #expect(await eventually { rig.watchOver.isWatching })
        #expect(rig.watcher.startCount == 1)

        await rig.feed(Self.moving, seconds: 5)
        await rig.feed(Self.still, seconds: 185)
        #expect(await eventually { rig.watchOver.isAwaitingConsent })
        #expect(Array(rig.h.voice.spoken.suffix(2)) == WatchOver.checkInLines)
        // 声かけは履歴にも残す（子どもの「うん」が返事だとわかるように）
        #expect(await rig.h.lastAssistantText()?.hasSuffix("どこか考え中？ちょっと見せて？") == true)
        #expect(rig.camera.captureCount == 0)

        await rig.h.transport.enqueue(.data, "/v1/claude", body: CaptureFlowTestsSupport.analysisResponse)
        await rig.h.enqueueReply(["長方形の問題だね。"])
        await rig.h.say("うん")
        #expect(await eventually { rig.h.voice.spoken.last == "長方形の問題だね。" })
        #expect(rig.camera.captureCount == 1)
        #expect(rig.h.voice.spoken.contains(StudySessionCoordinator.captureLead))
        // 撮影の間は見守りのカメラを止め、撮ったあとで戻す
        #expect(rig.watcher.stopCount >= 1)
        #expect(await eventually { rig.watcher.startCount == 2 && rig.watchOver.isWatching })
    }

    @Test func 断られたら撮らずにふつうに返事する() async throws {
        let rig = try Rig()
        await rig.startSession()
        _ = await eventually { rig.watchOver.isWatching }
        await rig.feed(Self.still, seconds: 185)
        #expect(await eventually { rig.watchOver.isAwaitingConsent })

        await rig.h.enqueueReply(["そっか、がんばってね。"])
        await rig.h.say("だいじょうぶ、自分でやる")
        #expect(await eventually { rig.h.voice.spoken.last == "そっか、がんばってね。" })
        #expect(rig.camera.captureCount == 0)
        #expect(!rig.watchOver.isAwaitingConsent)
    }

    @Test func 声をかけない方がよいと判断したら黙って見守る() async throws {
        let judge = StubNudgeJudge()
        judge.answer = false
        let rig = try Rig(judge: judge)
        await rig.startSession()
        _ = await eventually { rig.watchOver.isWatching }
        let spokenBefore = rig.h.voice.spoken.count
        await rig.feed(Self.still, seconds: 185)
        #expect(await eventually { judge.contexts.count == 1 })
        let context = try #require(judge.contexts.first)
        #expect(context.phase == .working)
        #expect(context.minutesStalled >= 3)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(rig.h.voice.spoken.count == spokenBefore)
        #expect(!rig.watchOver.isAwaitingConsent)
    }

    @Test func 判断を待つ間に子どもが話し始めたら声をかけない() async throws {
        let judge = StubNudgeJudge()
        judge.holds = true
        let rig = try Rig(judge: judge)
        await rig.startSession()
        _ = await eventually { rig.watchOver.isWatching }
        await rig.feed(Self.still, seconds: 185)
        #expect(await eventually { judge.contexts.count == 1 })
        // 子どもが話し始めた（聞き取り中）
        rig.h.input.say("えっとね")
        #expect(await eventually { rig.h.coordinator.conversationState == .listening })
        judge.release()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!rig.h.voice.spoken.contains(WatchOver.checkInLines[0]))
        #expect(!rig.watchOver.isAwaitingConsent)
    }

    @Test func 規則では先生が話したばかりなら声をかけない() {
        let context = NudgeContext(minutesStalled: 3, phase: .working, minutesSinceTeacherSpoke: 0.5)
        #expect(!JevNudgeJudge.ruleShouldSpeakUp(context, stalledMinutesThreshold: 3))
        #expect(JevNudgeJudge.ruleShouldSpeakUp(
            NudgeContext(minutesStalled: 2, phase: .working, minutesSinceTeacherSpoke: 2), stalledMinutesThreshold: 2
        ))
    }

    @Test func 席を立ったらタイマーを止め戻ったら動かす() async throws {
        let rig = try Rig()
        await rig.startSession()
        _ = await eventually { rig.watchOver.isWatching }
        await rig.feed(Self.still, seconds: 5)
        await rig.feed(Self.empty, seconds: 35)
        #expect(rig.h.coordinator.timer?.status == .paused)
        let remaining = try #require(rig.h.coordinator.timer?.remaining)
        await rig.feed(Self.empty, seconds: 60)
        #expect(rig.h.coordinator.timer?.remaining == remaining)
        await rig.feed(Self.still, seconds: 2)
        #expect(rig.h.coordinator.timer?.status == .running)
    }

    @Test func 見守らない設定ならカメラを使わない() async throws {
        let rig = try Rig(configuration: nil)
        await rig.startSession()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(rig.watcher.startCount == 0)
        #expect(!rig.watchOver.isWatching)
    }

    @Test func カメラを使えなくてもセッションは続く() async throws {
        let rig = try Rig()
        rig.watcher.fails = true
        await rig.startSession()
        #expect(await eventually { rig.h.coordinator.traceLines.contains { $0.contains("カメラを使えない") } })
        #expect(!rig.watchOver.isWatching)
        #expect(rig.h.coordinator.phase == .active)
    }

    @Test func 声かけのあとでなければうんと言っても撮らない() async throws {
        let rig = try Rig()
        await rig.startSession()
        _ = await eventually { rig.watchOver.isWatching }
        await rig.h.enqueueReply(["うんうん。"])
        await rig.h.say("ねえ先生、うん")
        #expect(await eventually { rig.h.voice.spoken.last == "うんうん。" })
        #expect(rig.camera.captureCount == 0)
    }

    @Test func セッションが終わったら見守りのカメラを止める() async throws {
        let rig = try Rig()
        await rig.startSession()
        #expect(await eventually { rig.watchOver.isWatching })
        await rig.h.coordinator.end()
        #expect(await eventually { !rig.watchOver.isWatching && !rig.watcher.isRunning })
    }

    @Test func 設定の初期値は3分で保存される() throws {
        let defaults = try #require(UserDefaults(suiteName: "WatchOverFlowTests-\(UUID().uuidString)"))
        let preferences = SessionPreferences(defaults: defaults)
        #expect(preferences.watchOverMinutes == 3)
        #expect(preferences.watchOverConfiguration == .minutes(3))
        preferences.watchOverMinutes = 0
        #expect(SessionPreferences(defaults: defaults).watchOverMinutes == 0)
        #expect(SessionPreferences(defaults: defaults).watchOverConfiguration == nil)
        preferences.watchOverMinutes = 5
        #expect(SessionPreferences(defaults: defaults).watchOverConfiguration?.stallAfter == .minutes(5))
    }
}

enum CaptureFlowTestsSupport {
    /// 分析（Sonnet）の応答
    static var analysisResponse: String {
        ProblemAnalyzerTests.response(blocks: [
            ProblemAnalyzerTests.toolUse("report_analysis", ProblemAnalyzerTests.thinkingInput),
        ])
    }
}
