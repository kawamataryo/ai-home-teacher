import Foundation
import Testing
@testable import HomeTeacher

struct AvatarStateMachineTests {
    private func run(_ events: [AvatarEvent]) -> AvatarStateMachine {
        var machine = AvatarStateMachine()
        for event in events { machine.handle(event) }
        return machine
    }

    @Test func 最初は待機() {
        #expect(AvatarStateMachine().state == .idle)
    }

    @Test func ふつうの会話の流れ() {
        var machine = AvatarStateMachine()
        #expect(machine.handle(.userStartedSpeaking) == .listening)
        #expect(machine.handle(.userStoppedSpeaking) == .idle)
        #expect(machine.handle(.thinkingStarted) == .thinking)
        #expect(machine.handle(.speakingStarted(emotion: .neutral)) == .talking)
        #expect(machine.handle(.speakingEnded) == .idle)
    }

    @Test(arguments: [
        (AvatarEmotion.neutral, AvatarState.talking),
        (.praise, .praise),
        (.encourage, .encourage),
    ])
    func 感情タグで話すときの状態が決まる(emotion: AvatarEmotion, expected: AvatarState) {
        let machine = run([.thinkingStarted, .speakingStarted(emotion: emotion)])
        #expect(machine.state == expected)
        #expect(machine.isSpeaking)
    }

    @Test func 話している途中に子どもが話し始めたら聞く() {
        let machine = run([.speakingStarted(emotion: .praise), .userStartedSpeaking])
        #expect(machine.state == .listening)
    }

    @Test func ノートを見る_話している間は見ない() {
        #expect(run([.lookAtNotebook]).state == .looking)
        #expect(run([.lookAtNotebook, .lookAwayFromNotebook]).state == .idle)
        #expect(run([.speakingStarted(emotion: .neutral), .lookAtNotebook]).state == .talking)
        // ノートを見ていないときに目をそらしても何も変わらない
        #expect(run([.thinkingStarted, .lookAwayFromNotebook]).state == .thinking)
    }

    @Test func 休憩中は話し終えると伸びに戻る() {
        let machine = run([
            .breakStarted,
            .userStartedSpeaking, .userStoppedSpeaking,
            .thinkingStarted, .speakingStarted(emotion: .neutral), .speakingEnded,
        ])
        #expect(machine.state == .break)
        #expect(machine.isOnBreak)
        #expect(run([.breakStarted, .breakEnded]).state == .idle)
    }

    @Test func 話している途中に休憩が始まったら話し終えてから伸び() {
        var machine = run([.speakingStarted(emotion: .encourage), .breakStarted])
        #expect(machine.state == .encourage)
        #expect(machine.handle(.speakingEnded) == .break)
    }

    @Test func 話していないのに話し終わりが来ても変わらない() {
        #expect(run([.lookAtNotebook, .speakingEnded]).state == .looking)
        #expect(run([.userStartedSpeaking, .speakingEnded]).state == .listening)
    }

    @Test(arguments: [
        ("praise", AvatarEmotion.praise),
        (" Encourage\n", .encourage),
        ("neutral", .neutral),
        ("happy", .neutral),
        (nil, .neutral),
    ] as [(String?, AvatarEmotion)])
    func 感情タグの文字列を読む(tag: String?, expected: AvatarEmotion) {
        #expect(AvatarEmotion(tag: tag) == expected)
    }

    @MainActor
    @Test func コントローラーはできごとで状態を更新する() {
        let controller = AvatarController()
        controller.send(.thinkingStarted)
        #expect(controller.state == .thinking)
        controller.send(.speakingStarted(emotion: .praise))
        #expect(controller.state == .praise)
    }
}

struct AvatarPoseTests {
    @Test func 喜ぶときは跳んでにっこり() {
        let pose = AvatarPose.make(state: .praise, timeInState: 0.3, time: 10)
        #expect(pose.lift > 0)
        #expect(pose.eyes == .happy)
    }

    @Test func ノートを見るときはうつむく() {
        let pose = AvatarPose.make(state: .looking, timeInState: 1, time: 1)
        let head = pose.joint(.head).rotation
        // X 軸まわりに正の角度（前に倒れる）
        #expect(head.axis.x > 0.9)
        #expect(head.angle > 0.3)
    }

    @Test func 伸びの途中は目を閉じる() {
        let pose = AvatarPose.make(state: .break, timeInState: 3, time: 3)
        #expect(pose.eyes == .closed)
        #expect(pose.lift > 0)
    }

    @Test func ときどきまばたきする() {
        let blinks = stride(from: 0.0, to: 10, by: 0.05).filter { AvatarPose.isBlinking(at: $0) }
        #expect(!blinks.isEmpty)
        #expect(blinks.count < 20)
    }

    @Test func 混ぜると両端の姿勢になる() {
        let a = AvatarPose.make(state: .idle, timeInState: 0, time: 0)
        let b = AvatarPose.make(state: .praise, timeInState: 0.3, time: 0)
        #expect(AvatarPose.blend(a, b, 0).lift == a.lift)
        #expect(abs(AvatarPose.blend(a, b, 1).lift - b.lift) < 1e-6)
        #expect(AvatarPose.blend(a, b, 1).eyes == .happy)
    }
}
