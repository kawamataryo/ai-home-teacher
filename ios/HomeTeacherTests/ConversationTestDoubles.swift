import Foundation
@testable import HomeTeacher

/// 手で進める時計。`advance(by:)` の中で期限が来た予約を同期的に実行する。
@MainActor
final class ManualClock: ConversationClock {
    private(set) var now: ContinuousClock.Instant = .now
    private var entries: [Entry] = []

    final class Entry: ScheduledAction {
        let fireAt: ContinuousClock.Instant
        let action: @MainActor () -> Void
        var isCancelled = false
        init(fireAt: ContinuousClock.Instant, action: @escaping @MainActor () -> Void) {
            self.fireAt = fireAt
            self.action = action
        }
        func cancel() { isCancelled = true }
    }

    func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void) -> any ScheduledAction {
        let entry = Entry(fireAt: now + delay, action: action)
        entries.append(entry)
        return entry
    }

    func advance(by duration: Duration) {
        let target = now + duration
        while let next = entries.filter({ !$0.isCancelled && $0.fireAt <= target }).min(by: { $0.fireAt < $1.fireAt }) {
            entries.removeAll { $0 === next }
            now = next.fireAt
            next.action()
        }
        now = target
    }
}

@MainActor
final class MockSpeechInput: SpeechInput {
    let events: AsyncStream<SpeechInputEvent>
    let continuation: AsyncStream<SpeechInputEvent>.Continuation
    private(set) var mutedHistory: [Bool] = []

    init() {
        (events, continuation) = AsyncStream.makeStream(of: SpeechInputEvent.self)
    }

    func setMuted(_ muted: Bool) { mutedHistory.append(muted) }
}

/// `holdsPlayback` が true のとき、`finishCurrent()` を呼ぶまで再生が終わらない。
@MainActor
final class MockSpeechOutput: SpeechOutput {
    var holdsPlayback = false
    private(set) var spoken: [String] = []
    private var playing: CheckedContinuation<Void, Never>?
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func speak(_ text: String) async {
        spoken.append(text)
        let waiters = startWaiters
        startWaiters = []
        waiters.forEach { $0.resume() }
        guard holdsPlayback else { return }
        await withCheckedContinuation { playing = $0 }
    }

    /// `count` 文目の再生が始まるまで待つ
    func waitUntilSpeaking(count: Int = 1) async {
        while spoken.count < count {
            await withCheckedContinuation { startWaiters.append($0) }
        }
    }

    func finishCurrent() {
        playing?.resume()
        playing = nil
    }
}

@MainActor
final class StubAddressingJudge: AddressingJudge {
    let result: Bool
    private(set) var asked: [String] = []
    init(_ result: Bool) { self.result = result }
    func isAddressedToTeacher(_ utterance: String) async -> Bool {
        asked.append(utterance)
        return result
    }
}

/// 呼ばれたら `onCall` を実行してその結果を返す。
@MainActor
final class StubEndOfUtteranceDecider: EndOfUtteranceDecider {
    var onCall: @MainActor (String) -> Bool
    private(set) var asked: [String] = []
    private var callWaiters: [CheckedContinuation<Void, Never>] = []

    init(_ onCall: @escaping @MainActor (String) -> Bool) { self.onCall = onCall }

    func isUtteranceComplete(_ transcript: String) async -> Bool {
        asked.append(transcript)
        let waiters = callWaiters
        callWaiters = []
        waiters.forEach { $0.resume() }
        return onCall(transcript)
    }

    func waitUntilAsked(count: Int = 1) async {
        while asked.count < count {
            await withCheckedContinuation { callWaiters.append($0) }
        }
    }
}

/// コントローラとモック一式。
@MainActor
final class ConversationHarness {
    let input = MockSpeechInput()
    let output = MockSpeechOutput()
    let clock = ManualClock()
    let controller: ConversationController

    init(
        settings: ConversationSettings = ConversationSettings(),
        addressingJudge: (any AddressingJudge)? = nil,
        endOfUtteranceDecider: (any EndOfUtteranceDecider)? = nil
    ) {
        controller = ConversationController(
            input: input,
            output: output,
            clock: clock,
            settings: settings,
            addressingJudge: addressingJudge,
            endOfUtteranceDecider: endOfUtteranceDecider
        )
    }

    /// 話し始めて、書き起こしが届き、声が止まるところまで
    func say(_ text: String) {
        controller.handle(.voiceStarted)
        controller.handle(.transcript(text))
        controller.handle(.voiceEnded)
    }

    /// 話して、無音で区切られた結果の出来事を返す
    func sayAndFinish(_ text: String) async -> ConversationEvent? {
        say(text)
        clock.advance(by: controller.settings.endOfUtteranceSilence)
        return await nextEvent()
    }

    func nextEvent() async -> ConversationEvent? {
        for await event in controller.events {
            return event
        }
        return nil
    }
}
