import RealityKit
import SwiftUI

/// 先生のアバター。状態（`AvatarState`）と口の形（`MouthShape`）を受け取り、キャラの形式に合わせて表示する（#121）
///
/// - `voxel`：パーツごとに動かす 3D（今の先生）
/// - `rigged`：骨とシェイプキーで動かす 3D
/// - `paper` / `chalk`：SwiftUI で描く 2D
///
/// 会話とつなぐときは `AvatarController` にできごと（`AvatarEvent`）を送り、
/// `AvatarView(state: controller.state, lipSync: player, look: character.look)` で表示する。
/// 口パクは `LipSyncPlayer` に TTS の再生時刻（または音量）を渡すと動く。
/// 読み込みに失敗したら既定の先生を出して、会話を止めない。
struct AvatarView: View {
    var state: AvatarState = .idle
    var lipSync: LipSyncPlayer? = nil
    /// 確認用に口の形を固定する（nil なら口パクに任せる）
    var mouth: MouthShape? = nil
    /// 体の向き（度。正で画面の左を向く）。黒板に書いて話すときに黒板の方へ体を向ける（#105）
    var turn: Double = 0
    var look: CharacterLook = .haru

    /// 読み込めなかった見た目。これを選んでいる間は既定の先生を出す
    @State private var failedLook: CharacterLook?

    var body: some View {
        let shown = failedLook == look ? CharacterLook.haru : look
        Group {
            switch shown.kind {
            case .voxel:
                VoxelAvatarView(
                    state: state, lipSync: lipSync, mouth: mouth, turn: turn, look: shown,
                    onLoadFailed: { failedLook = shown }
                )
            case .rigged:
                RiggedAvatarView(
                    state: state, lipSync: lipSync, mouth: mouth, turn: turn, look: shown,
                    onLoadFailed: { failedLook = shown }
                )
            case .paper, .chalk:
                PaperAvatarView(state: state, lipSync: lipSync, mouth: mouth, turn: turn)
            }
        }
        // キャラが替わったら作り直す。同じキャラなら作り直さない（#105）
        .id(shown)
    }
}

/// パーツごとに動かす 3D（ボクセルのキャラ）。`TeacherModel` と `AvatarPose` の 10 パーツの前提はこの中に閉じる
struct VoxelAvatarView: View {
    var state: AvatarState
    var lipSync: LipSyncPlayer?
    var mouth: MouthShape?
    var turn: Double
    var look: CharacterLook
    var onLoadFailed: () -> Void

    @State private var animator: AvatarAnimator?
    @State private var updateSubscription: EventSubscription?
    @State private var loadError: String?

    var body: some View {
        RealityView { content in
            content.camera = .virtual
            let camera = PerspectiveCamera()
            camera.camera.fieldOfViewInDegrees = 35
            camera.look(at: [0, 0.65, 0], from: [0.7, 0.95, 3.2], relativeTo: nil)
            content.add(camera)

            let sun = DirectionalLight()
            sun.light.intensity = 3_000
            sun.look(at: .zero, from: [1.2, 2.5, 2.5], relativeTo: nil)
            content.add(sun)

            do {
                let loaded = try await TeacherModel.load(name: look.modelName, faceTextures: look.faceTexturePrefix)
                try await loaded.preloadFaceTextures()
                let animator = AvatarAnimator(model: loaded)
                animator.setState(state)
                animator.lipSync = lipSync
                animator.mouthOverride = mouth
                animator.targetYaw = AvatarView.yaw(turn)
                content.add(animator.rig)
                updateSubscription = content.subscribe(to: SceneEvents.Update.self) { event in
                    MainActor.assumeIsolated {
                        animator.update(deltaTime: event.deltaTime)
                    }
                }
                self.animator = animator
            } catch {
                loadError = "\(error)"
                if look != .haru { onLoadFailed() }
            }
        } update: { _ in
            animator?.setState(state)
            if animator?.lipSync !== lipSync { animator?.lipSync = lipSync }
            animator?.mouthOverride = mouth
            animator?.targetYaw = AvatarView.yaw(turn)
        }
        .overlay {
            if let loadError, look == .haru {
                Text("先生を読み込めませんでした: \(loadError)")
                    .foregroundStyle(.red)
                    .padding()
            }
        }
    }
}

extension AvatarView {
    /// 画面の左を向く向きを、上から見た回転（ラジアン）にする。先生は +z（カメラ側）を向いて立っている
    static func yaw(_ degrees: Double) -> Float {
        -Float(degrees * .pi / 180)
    }
}

#Preview {
    AvatarView(state: .praise)
}
