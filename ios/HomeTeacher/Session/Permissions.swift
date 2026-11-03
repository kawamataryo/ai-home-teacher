@preconcurrency import AVFoundation
import Observation
import Speech

/// アプリが使う許可（#66）。聞く順番もこの順（マイク → 音声認識 → カメラ）
enum AppPermission: String, CaseIterable, Sendable {
    case microphone
    case speech
    case camera
}

enum PermissionState: Equatable, Sendable {
    case notDetermined
    case granted
    /// 拒否・制限（設定アプリでしか変えられない）
    case denied
}

/// 許可の状態を読み、システムのダイアログで求める口。テストではモックに差し替える
@MainActor
protocol PermissionAuthorizing: AnyObject {
    func state(of permission: AppPermission) -> PermissionState
    /// システムのダイアログを出す。許可されたら true
    func request(_ permission: AppPermission) async -> Bool
    /// カメラがある端末か（ないならカメラの許可は聞かない）
    var hasCamera: Bool { get }
}

/// 本番の実装
@MainActor
final class SystemPermissions: PermissionAuthorizing {
    func state(of permission: AppPermission) -> PermissionState {
        switch permission {
        case .microphone:
            switch AVAudioApplication.shared.recordPermission {
            case .granted: .granted
            case .denied: .denied
            default: .notDetermined
            }
        case .speech:
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized: .granted
            case .denied, .restricted: .denied
            default: .notDetermined
            }
        case .camera:
            Self.cameraState
        }
    }

    nonisolated static var cameraState: PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: .granted
        case .denied, .restricted: .denied
        default: .notDetermined
        }
    }

    func request(_ permission: AppPermission) async -> Bool {
        switch permission {
        case .microphone:
            await AVAudioApplication.requestRecordPermission()
        case .speech:
            await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
        case .camera:
            await AVCaptureDevice.requestAccess(for: .video)
        }
    }

    var hasCamera: Bool { CameraCapture.hasCamera }
}

/// 初めて起動したときの許可の流れ（#66）。いきなりシステムのダイアログを出さず、先生が理由を話してから
/// 「いいよ」のボタンでダイアログを出す。まだ聞いていない許可だけを、マイク → 音声認識 → カメラの順に聞く。
@MainActor
@Observable
final class PermissionOnboarding {
    /// いま理由を話している許可。終わったら nil
    private(set) var current: AppPermission?

    @ObservationIgnored private let authorizer: any PermissionAuthorizing
    @ObservationIgnored private let voice: (any TeacherSpeaking)?
    @ObservationIgnored private var tap: CheckedContinuation<Void, Never>?

    init(authorizer: any PermissionAuthorizing, voice: (any TeacherSpeaking)?) {
        self.authorizer = authorizer
        self.voice = voice
    }

    /// まだ聞いていない許可（聞く順）
    static func pending(_ authorizer: any PermissionAuthorizing) -> [AppPermission] {
        AppPermission.allCases.filter { permission in
            if permission == .camera, !authorizer.hasCamera { return false }
            return authorizer.state(of: permission) == .notDetermined
        }
    }

    /// 先生がいまの許可を使う理由（声に出す）
    static func explanation(for permission: AppPermission) -> String {
        switch permission {
        case .microphone:
            "はじめまして！先生とお話しするのに、マイクを使わせてね。「いいよ」を押すと、許可を聞く画面が出るよ。"
        case .speech:
            "話してくれた言葉を先生がわかるように、音声認識も使わせてね。"
        case .camera:
            "ノートを見せてもらうのと、勉強を見守るのに、カメラも使わせてね。写真はとっておかないよ。"
        }
    }

    /// まだ聞いていない許可を順に聞く。全部聞き終わったら戻る
    func run() async {
        for permission in Self.pending(authorizer) {
            current = permission
            let line = Self.explanation(for: permission)
            let speaking = Task { await voice?.speak(line) }
            await waitForTap()
            // 話している途中で押されたら止めて、ダイアログを出す
            voice?.stop()
            _ = await speaking.value
            _ = await authorizer.request(permission)
        }
        current = nil
    }

    /// 画面の「いいよ」
    func proceed() {
        tap?.resume()
        tap = nil
    }

    private func waitForTap() async {
        await withCheckedContinuation { continuation in tap = continuation }
    }
}

/// 表示確認用（起動引数 `-deniedPermissions microphone,camera`）。書いた許可は拒否、ほかは許可済みとして扱う。
/// シミュレーターでは音声認識とカメラの許可を `simctl privacy` で変えられないので、拒否の画面はこれで確かめる
@MainActor
final class FixedPermissions: PermissionAuthorizing {
    let denied: Set<AppPermission>
    let hasCamera = true

    init(denied: Set<AppPermission>) {
        self.denied = denied
    }

    static func fromLaunchArguments(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> FixedPermissions? {
        guard let index = arguments.firstIndex(of: "-deniedPermissions"), index + 1 < arguments.count else { return nil }
        let names = arguments[index + 1].split(separator: ",").map(String.init)
        return FixedPermissions(denied: Set(names.compactMap(AppPermission.init(rawValue:))))
    }

    func state(of permission: AppPermission) -> PermissionState {
        denied.contains(permission) ? .denied : .granted
    }

    func request(_ permission: AppPermission) async -> Bool { !denied.contains(permission) }
}

/// 許可が拒否されているときの案内（#66）。子ども向けのひと言と、保護者向けの設定のしかた
struct PermissionNotice: Equatable, Sendable {
    /// 使えないもの（聞く順）
    let denied: [AppPermission]

    /// 拒否されているものがなければ nil。音声認識は、聞き取りを始められなかったときだけ出す（端末の中の認識は許可がいらないことがある）
    init?(states: [AppPermission: PermissionState], speechInputFailed: Bool) {
        let denied = AppPermission.allCases.filter { permission in
            guard states[permission] == .denied else { return false }
            return permission != .speech || speechInputFailed
        }
        guard !denied.isEmpty else { return nil }
        self.denied = denied
    }

    /// 声で会話できるか（カメラだけの拒否なら会話は続けられる）
    var canTalk: Bool { !denied.contains(.microphone) && !denied.contains(.speech) }

    /// 先生が話すひと言
    var childLine: String {
        let parent = "お父さん・お母さんに、設定アプリで許可してもらってね。"
        if !canTalk {
            let what = denied.contains(.microphone) ? "マイク" : "音声認識"
            return "\(what)が使えないから、先生と声でお話しできないんだ。\(parent)"
        }
        return "カメラが使えないから、ノートは見られないけど、お話はできるよ。カメラを使うときは、\(parent)"
    }

    /// 画面に出す保護者向けの案内
    var parentMessage: String {
        let names = denied.map(Self.label).joined(separator: "・")
        let effect = canTalk
            ? "カメラを使う撮影（「これ見て」）と見守りはお休みします。声の会話はできます。"
            : "声で話しかけても聞き取れません。ボタンだけで動きます。"
        return "\(names)が許可されていません。\(effect)設定アプリ > アプリ > AI家庭教師 で許可してください。"
    }

    static func label(_ permission: AppPermission) -> String {
        switch permission {
        case .microphone: "マイク"
        case .speech: "音声認識"
        case .camera: "カメラ"
        }
    }
}
