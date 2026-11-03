import Foundation
import Testing
@testable import HomeTeacher

/// 届いた声かけを記録するだけの届け先。
@MainActor
final class RecordingNudgeSink: NudgeSink {
    private(set) var delivered: [TeacherNudge] = []
    var phrases: [FixedPhrase] { delivered.map(\.phrase) }
    func deliver(_ nudge: TeacherNudge) { delivered.append(nudge) }
}

@MainActor
final class FocusTimerHarness {
    let clock = ManualClock()
    let sink = RecordingNudgeSink()
    let timer: FocusTimer

    init(settings: FocusTimerSettings = FocusTimerSettings()) {
        timer = FocusTimer(clock: clock, settings: settings, nudgeSink: sink)
    }

    /// 出来事を `count` 個読む
    func nextEvents(_ count: Int) async -> [FocusTimerEvent] {
        var result: [FocusTimerEvent] = []
        for await event in timer.events {
            result.append(event)
            if result.count == count { break }
        }
        return result
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct FocusTimerTests {
    // MARK: - 状態の遷移

    @Test func 始める前は止まっていて休憩でもない() {
        let h = FocusTimerHarness()
        #expect(h.timer.status == .stopped)
        #expect(h.timer.isOnBreak == false)
    }

    @Test func 集中25分のあと休憩5分になり_また集中に戻る() {
        let h = FocusTimerHarness()
        h.timer.start()
        #expect(h.timer.status == .running)
        #expect(h.timer.phase == .focus)
        #expect(h.timer.remaining == .minutes(25))

        h.clock.advance(by: .minutes(25) - .seconds(1))
        #expect(h.timer.phase == .focus)
        #expect(h.timer.remaining == .seconds(1))

        h.clock.advance(by: .seconds(1))
        #expect(h.timer.phase == .rest)
        #expect(h.timer.remaining == .minutes(5))
        #expect(h.timer.completedFocusCount == 1)

        h.clock.advance(by: .minutes(5))
        #expect(h.timer.phase == .focus)
        #expect(h.timer.remaining == .minutes(25))
        #expect(h.timer.completedFocusCount == 1)
    }

    @Test func 一度に時間を進めても区切りを順に通る() {
        let h = FocusTimerHarness()
        h.timer.start()
        // 集中 25 → 休憩 5 → 集中 25 → 休憩に入って 2 分
        h.clock.advance(by: .minutes(57))
        #expect(h.timer.phase == .rest)
        #expect(h.timer.remaining == .minutes(3))
        #expect(h.timer.completedFocusCount == 2)
        #expect(h.sink.phrases == [.fiveMinutesLeft, .breakTime, .breakOver, .fiveMinutesLeft, .breakTime])
    }

    @Test func 出来事として区切りの始まりを知らせる() async {
        let h = FocusTimerHarness()
        h.timer.start()
        h.clock.advance(by: .minutes(30))
        h.timer.stop()
        #expect(await h.nextEvents(4) == [.phaseStarted(.focus), .phaseStarted(.rest), .phaseStarted(.focus), .stopped])
    }

    @Test func 止めると予約した区切りも声かけも起きない() {
        let h = FocusTimerHarness()
        h.timer.start()
        h.clock.advance(by: .minutes(10))
        h.timer.stop()
        #expect(h.timer.status == .stopped)
        h.clock.advance(by: .minutes(60))
        #expect(h.timer.status == .stopped)
        #expect(h.sink.delivered.isEmpty)
    }

    @Test func 動いている途中で始め直すと集中の最初からになる() {
        let h = FocusTimerHarness()
        h.timer.start()
        h.clock.advance(by: .minutes(27))
        #expect(h.timer.phase == .rest)
        h.timer.start()
        #expect(h.timer.phase == .focus)
        #expect(h.timer.remaining == .minutes(25))
        #expect(h.timer.completedFocusCount == 0)
        // 前の休憩の終わりは取り消されている
        h.clock.advance(by: .minutes(3))
        #expect(h.timer.phase == .focus)
    }

    // MARK: - 設定

    @Test func 集中と休憩の長さを変えられる() {
        let h = FocusTimerHarness(settings: FocusTimerSettings(focusDuration: .minutes(15), breakDuration: .minutes(3)))
        h.timer.start()
        #expect(h.timer.currentPhaseDuration == .minutes(15))
        h.clock.advance(by: .minutes(15))
        #expect(h.timer.phase == .rest)
        #expect(h.timer.currentPhaseDuration == .minutes(3))
        h.clock.advance(by: .minutes(3))
        #expect(h.timer.phase == .focus)
    }

    // MARK: - 一時停止

    @Test func 一時停止中は残り時間が減らず_再開すると続きから数える() {
        let h = FocusTimerHarness()
        h.timer.start()
        h.clock.advance(by: .minutes(10))
        h.timer.pause()
        #expect(h.timer.status == .paused)
        #expect(h.timer.remaining == .minutes(15))

        h.clock.advance(by: .minutes(30))
        #expect(h.timer.phase == .focus)
        #expect(h.timer.remaining == .minutes(15))
        #expect(h.sink.delivered.isEmpty)

        h.timer.resume()
        #expect(h.timer.status == .running)
        h.clock.advance(by: .minutes(15) - .seconds(1))
        #expect(h.timer.phase == .focus)
        h.clock.advance(by: .seconds(1))
        #expect(h.timer.phase == .rest)
    }

    @Test func 一時停止と再開を出来事で知らせる() async {
        let h = FocusTimerHarness()
        h.timer.start()
        h.timer.pause()
        h.timer.pause()
        h.timer.resume()
        h.timer.resume()
        h.timer.stop()
        #expect(await h.nextEvents(4) == [.phaseStarted(.focus), .paused, .resumed, .stopped])
    }

    @Test func 止まっているときの一時停止と再開は何もしない() {
        let h = FocusTimerHarness()
        h.timer.pause()
        #expect(h.timer.status == .stopped)
        h.timer.resume()
        #expect(h.timer.status == .stopped)
    }

    // MARK: - 声かけ

    @Test func 集中の終わり5分前に励まし_終わりに休憩_休憩の終わりに再開の声をかける() {
        let h = FocusTimerHarness()
        h.timer.start()

        h.clock.advance(by: .minutes(20) - .seconds(1))
        #expect(h.sink.delivered.isEmpty)
        h.clock.advance(by: .seconds(1))
        #expect(h.sink.phrases == [.fiveMinutesLeft])

        h.clock.advance(by: .minutes(5))
        #expect(h.sink.phrases == [.fiveMinutesLeft, .breakTime])

        h.clock.advance(by: .minutes(5))
        #expect(h.sink.phrases == [.fiveMinutesLeft, .breakTime, .breakOver])
    }

    @Test func 励ましを出したあとに一時停止して再開しても2回は出さない() {
        let h = FocusTimerHarness()
        h.timer.start()
        h.clock.advance(by: .minutes(21))
        h.timer.pause()
        h.timer.resume()
        h.clock.advance(by: .minutes(4))
        #expect(h.sink.phrases == [.fiveMinutesLeft, .breakTime])
    }

    @Test func 励ましの前に一時停止したら_再開後に残り5分で出す() {
        let h = FocusTimerHarness()
        h.timer.start()
        h.clock.advance(by: .minutes(10))
        h.timer.pause()
        h.clock.advance(by: .minutes(10))
        h.timer.resume()
        h.clock.advance(by: .minutes(10) - .seconds(1))
        #expect(h.sink.delivered.isEmpty)
        h.clock.advance(by: .seconds(1))
        #expect(h.sink.phrases == [.fiveMinutesLeft])
    }

    @Test func 励ましは設定で切れる() {
        let h = FocusTimerHarness(settings: FocusTimerSettings(encouragesBeforeFocusEnds: false))
        h.timer.start()
        h.clock.advance(by: .minutes(25))
        #expect(h.sink.phrases == [.breakTime])
    }

    @Test func 集中が5分以下なら励ましは出さない() {
        let h = FocusTimerHarness(settings: FocusTimerSettings(focusDuration: .minutes(5)))
        h.timer.start()
        h.clock.advance(by: .minutes(5))
        #expect(h.sink.phrases == [.breakTime])
    }

    @Test func 言い回しを変えてよいかを声かけに載せる() {
        let h = FocusTimerHarness(settings: FocusTimerSettings(allowsVariation: true))
        h.timer.start()
        h.clock.advance(by: .minutes(25))
        #expect(h.sink.delivered.allSatisfy { $0.allowsVariation })
        #expect(h.sink.delivered.map(\.text) == ["あと5分がんばろう", "そろそろ休憩しよっか"])
    }

    @Test func 定型句のキーと文() {
        #expect(FixedPhrase.breakTime.rawValue == "break_time")
        #expect(FixedPhrase.breakTime.text == "そろそろ休憩しよっか")
        #expect(FixedPhrase.breakOver.text == "休憩おわり！続きやろう")
        #expect(FixedPhrase.fiveMinutesLeft.text == "あと5分がんばろう")
        #expect(Set(FixedPhrase.allCases.map(\.rawValue)).count == FixedPhrase.allCases.count)
    }

    // MARK: - 休憩中（雑談モード）

    @Test func 休憩中だけisOnBreakがtrueで_一時停止中も休憩のまま() {
        let h = FocusTimerHarness()
        h.timer.start()
        #expect(h.timer.isOnBreak == false)
        h.clock.advance(by: .minutes(25))
        #expect(h.timer.isOnBreak)
        h.timer.pause()
        #expect(h.timer.isOnBreak)
        h.timer.resume()
        h.clock.advance(by: .minutes(5))
        #expect(h.timer.isOnBreak == false)
        h.clock.advance(by: .minutes(25))
        #expect(h.timer.isOnBreak)
        h.timer.stop()
        #expect(h.timer.isOnBreak == false)
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ConversationNudgeSpeakerTests {
    /// 待機に戻ったあとの話し始めは Task を挟むので、少し回して待つ
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    @Test func 待機中ならすぐに話す() async {
        let h = ConversationHarness()
        let speaker = ConversationNudgeSpeaker(controller: h.controller)
        speaker.deliver(TeacherNudge(.breakTime))
        await h.output.waitUntilSpeaking()
        #expect(h.output.spoken == ["そろそろ休憩しよっか"])
        #expect(speaker.pending == nil)
    }

    @Test func 聞き取り中は話さず_待機に戻ってから話す() async {
        let h = ConversationHarness()
        let speaker = ConversationNudgeSpeaker(controller: h.controller)
        h.controller.handle(.voiceStarted)
        #expect(h.controller.state == .listening)

        speaker.deliver(TeacherNudge(.breakTime))
        await settle()
        #expect(h.output.spoken.isEmpty)
        #expect(speaker.pending == TeacherNudge(.breakTime))

        // 物音だけだったので待機に戻る
        h.controller.handle(.voiceEnded)
        h.clock.advance(by: h.controller.settings.endOfUtteranceSilence)
        #expect(h.controller.state == .idle)
        await h.output.waitUntilSpeaking()
        #expect(h.output.spoken == ["そろそろ休憩しよっか"])
    }

    @Test func 考え中は話さず_先生の返事が終わってから話す() async {
        let h = ConversationHarness()
        let speaker = ConversationNudgeSpeaker(controller: h.controller)
        #expect(await h.sayAndFinish("先生、これわかんない") == .userTurnAccepted("先生、これわかんない"))
        #expect(h.controller.state == .thinking)

        speaker.deliver(TeacherNudge(.breakTime))
        await settle()
        #expect(h.output.spoken.isEmpty)

        #expect(await h.controller.speak("どこがわからない？") == .completed)
        await h.output.waitUntilSpeaking(count: 2)
        #expect(h.output.spoken == ["どこがわからない？", "そろそろ休憩しよっか"])
    }

    @Test func 発話中は話さず_話し終わってから話す() async {
        let h = ConversationHarness()
        let speaker = ConversationNudgeSpeaker(controller: h.controller)
        h.output.holdsPlayback = true
        let reply = Task { await h.controller.speak("いいね！") }
        await h.output.waitUntilSpeaking()
        #expect(h.controller.state == .speaking)

        speaker.deliver(TeacherNudge(.breakOver))
        await settle()
        #expect(h.output.spoken == ["いいね！"])

        h.output.holdsPlayback = false
        h.output.finishCurrent()
        #expect(await reply.value == .completed)
        await h.output.waitUntilSpeaking(count: 2)
        #expect(h.output.spoken == ["いいね！", "休憩おわり！続きやろう"])
    }

    @Test func 待っている間に次の声かけが来たら新しいほうだけ話す() async {
        let h = ConversationHarness()
        let speaker = ConversationNudgeSpeaker(controller: h.controller)
        h.controller.handle(.voiceStarted)

        speaker.deliver(TeacherNudge(.fiveMinutesLeft))
        speaker.deliver(TeacherNudge(.breakTime))
        await settle()
        #expect(h.output.spoken.isEmpty)

        h.controller.handle(.voiceEnded)
        h.clock.advance(by: h.controller.settings.endOfUtteranceSilence)
        await h.output.waitUntilSpeaking()
        await settle()
        #expect(h.output.spoken == ["そろそろ休憩しよっか"])
    }

    @Test func タイマーの区切りが子どもの話している最中なら_話し終わってから声をかける() async {
        let h = ConversationHarness()
        let speaker = ConversationNudgeSpeaker(controller: h.controller)
        let timer = FocusTimer(
            clock: h.clock,
            settings: FocusTimerSettings(encouragesBeforeFocusEnds: false),
            nudgeSink: speaker
        )
        timer.start()
        h.clock.advance(by: .minutes(24))
        h.controller.handle(.voiceStarted)
        h.clock.advance(by: .minutes(1))
        #expect(timer.isOnBreak)
        await settle()
        #expect(h.output.spoken.isEmpty)

        h.controller.handle(.voiceEnded)
        h.clock.advance(by: h.controller.settings.endOfUtteranceSilence)
        await h.output.waitUntilSpeaking()
        #expect(h.output.spoken == ["そろそろ休憩しよっか"])
    }
}
