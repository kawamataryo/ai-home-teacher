import Foundation
import Testing
@testable import HomeTeacher

/// 許可の状態のモック。`request` を呼ぶと `answers` の答えで状態が決まる
@MainActor
final class MockPermissions: PermissionAuthorizing {
    var states: [AppPermission: PermissionState]
    var answers: [AppPermission: Bool] = [:]
    var hasCamera: Bool
    private(set) var requested: [AppPermission] = []

    init(states: [AppPermission: PermissionState] = [:], hasCamera: Bool = true) {
        self.states = states
        self.hasCamera = hasCamera
    }

    func state(of permission: AppPermission) -> PermissionState {
        states[permission] ?? .notDetermined
    }

    func request(_ permission: AppPermission) async -> Bool {
        requested.append(permission)
        let granted = answers[permission] ?? true
        states[permission] = granted ? .granted : .denied
        return granted
    }
}

/// 初めての許可の流れと、拒否されたときの案内（#66）
@MainActor
struct PermissionOnboardingTests {
    @Test func まだ聞いていない許可をマイク音声認識カメラの順に聞く() {
        #expect(PermissionOnboarding.pending(MockPermissions()) == [.microphone, .speech, .camera])
        #expect(PermissionOnboarding.pending(MockPermissions(states: [.microphone: .granted])) == [.speech, .camera])
        // 拒否したものは聞き直さない（ダイアログはもう出ない）
        #expect(PermissionOnboarding.pending(MockPermissions(states: [.microphone: .denied, .speech: .granted])) == [.camera])
    }

    @Test func カメラがない端末ではカメラを聞かない() {
        #expect(PermissionOnboarding.pending(MockPermissions(hasCamera: false)) == [.microphone, .speech])
    }

    @Test func 先生が理由を話してからいいよでシステムのダイアログを出す() async {
        let permissions = MockPermissions()
        let voice = MockTeacherVoice()
        let onboarding = PermissionOnboarding(authorizer: permissions, voice: voice)
        let run = Task { await onboarding.run() }

        #expect(await eventually { onboarding.current == .microphone })
        #expect(await eventually { voice.spoken == [PermissionOnboarding.explanation(for: .microphone)] })
        // 押すまではダイアログを出さない
        try? await Task.sleep(for: .milliseconds(30))
        #expect(permissions.requested.isEmpty)

        onboarding.proceed()
        #expect(await eventually { onboarding.current == .speech })
        #expect(permissions.requested == [.microphone])
        onboarding.proceed()
        #expect(await eventually { onboarding.current == .camera })
        onboarding.proceed()
        await run.value

        #expect(onboarding.current == nil)
        #expect(permissions.requested == [.microphone, .speech, .camera])
        #expect(voice.spoken == AppPermission.allCases.map(PermissionOnboarding.explanation(for:)))
        #expect(PermissionOnboarding.pending(permissions).isEmpty)
    }

    @Test func 全部聞いてあれば何もしない() async {
        let permissions = MockPermissions(states: [.microphone: .granted, .speech: .granted, .camera: .denied])
        let voice = MockTeacherVoice()
        await PermissionOnboarding(authorizer: permissions, voice: voice).run()
        #expect(permissions.requested.isEmpty)
        #expect(voice.spoken.isEmpty)
    }

    @Test func マイクが拒否されたら声の会話ができないと伝え設定アプリを案内する() throws {
        let notice = try #require(PermissionNotice(states: [.microphone: .denied, .speech: .granted, .camera: .granted], speechInputFailed: true))
        #expect(notice.denied == [.microphone])
        #expect(!notice.canTalk)
        #expect(notice.childLine.contains("マイク"))
        #expect(notice.childLine.contains("お父さん・お母さんに、設定アプリで許可してもらってね"))
        #expect(notice.parentMessage.contains("設定アプリ"))
    }

    @Test func カメラだけ拒否なら声の会話は続けられる() throws {
        let notice = try #require(PermissionNotice(states: [.microphone: .granted, .speech: .granted, .camera: .denied], speechInputFailed: false))
        #expect(notice.canTalk)
        #expect(notice.childLine.contains("お話はできるよ"))
        #expect(notice.parentMessage.contains("声の会話はできます"))
    }

    @Test func 音声認識の拒否は聞き取りを始められなかったときだけ伝える() {
        let states: [AppPermission: PermissionState] = [.microphone: .granted, .speech: .denied, .camera: .granted]
        // 端末の中の認識が動いていれば困らない
        #expect(PermissionNotice(states: states, speechInputFailed: false) == nil)
        #expect(PermissionNotice(states: states, speechInputFailed: true)?.canTalk == false)
        #expect(PermissionNotice(states: [.microphone: .granted, .speech: .granted], speechInputFailed: false) == nil)
    }
}
