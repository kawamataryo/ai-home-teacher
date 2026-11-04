import RealityKit
import SwiftUI

/// 先生のアバターを RealityKit で表示するビュー。`state` に合わせて動く
///
/// 会話とつなぐときは `AvatarController` にできごと（`AvatarEvent`）を送り、
/// `AvatarView(state: controller.state, lipSync: player)` で表示する。
/// 口パクは `LipSyncPlayer` に TTS の再生時刻（または音量）を渡すと動く。
struct AvatarView: View {
    var state: AvatarState = .idle
    var lipSync: LipSyncPlayer? = nil
    /// 確認用に口の形を固定する（nil なら口パクに任せる）
    var mouth: MouthShape? = nil
    /// 体の向き（度。正で画面の左を向く）。黒板に書いて話すときに黒板の方へ体を向ける（#105）
    var turn: Double = 0

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
                let loaded = try await TeacherModel.load()
                try await loaded.preloadFaceTextures()
                let animator = AvatarAnimator(model: loaded)
                animator.setState(state)
                animator.lipSync = lipSync
                animator.mouthOverride = mouth
                animator.targetYaw = Self.yaw(turn)
                content.add(animator.rig)
                updateSubscription = content.subscribe(to: SceneEvents.Update.self) { event in
                    MainActor.assumeIsolated {
                        animator.update(deltaTime: event.deltaTime)
                    }
                }
                self.animator = animator
            } catch {
                loadError = "\(error)"
            }
        } update: { _ in
            animator?.setState(state)
            if animator?.lipSync !== lipSync { animator?.lipSync = lipSync }
            animator?.mouthOverride = mouth
            animator?.targetYaw = Self.yaw(turn)
        }
        .overlay {
            if let loadError {
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
