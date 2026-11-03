import RealityKit
import SwiftUI

/// 先生のアバターを RealityKit で表示するビュー
struct AvatarView: View {
    /// 確認用に口のテクスチャを固定する（nil ならふだんの口）
    var mouthTextureName: String? = nil
    var eyes: EyeShape = .open

    @State private var model: TeacherModel?
    @State private var loadError: String?

    var body: some View {
        RealityView { content in
            content.camera = .virtual
            let camera = PerspectiveCamera()
            camera.camera.fieldOfViewInDegrees = 35
            camera.look(at: [0, 0.6, 0], from: [0.7, 0.9, 3.0], relativeTo: nil)
            content.add(camera)

            let sun = DirectionalLight()
            sun.light.intensity = 3_000
            sun.look(at: .zero, from: [1.2, 2.5, 2.5], relativeTo: nil)
            content.add(sun)

            do {
                let loaded = try await TeacherModel.load()
                try await loaded.preloadFaceTextures()
                content.add(loaded.entity)
                loaded.setEyes(eyes)
                loaded.setMouthTexture(named: mouthTextureName ?? "face_mouth_closed")
                model = loaded
            } catch {
                loadError = "\(error)"
            }
        } update: { _ in
            model?.setEyes(eyes)
            model?.setMouthTexture(named: mouthTextureName ?? "face_mouth_closed")
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

#Preview {
    AvatarView()
}
