import SwiftUI

/// デバッグ用: 先生の状態と顔テクスチャを確認する画面
///
/// 起動引数 `-avatarState thinking` で最初の状態を指定できる（スクリーンショット用）。
struct AvatarGalleryView: View {
    @State private var state: AvatarState =
        AvatarState(rawValue: UserDefaults.standard.string(forKey: "avatarState") ?? "") ?? .idle
    @State private var mouth = "face_mouth_closed"

    var body: some View {
        VStack {
            Text(state.rawValue)
                .font(.title2.monospaced())
            AvatarView(state: state, mouthTextureName: mouth)
            Picker("状態", selection: $state) {
                ForEach(AvatarState.allCases, id: \.self) { state in
                    Text(state.rawValue).tag(state)
                }
            }
            .pickerStyle(.segmented)
            Picker("口", selection: $mouth) {
                ForEach(TeacherModel.mouthTextureNames, id: \.self) { name in
                    Text(name.replacingOccurrences(of: "face_mouth_", with: "")).tag(name)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding()
        .navigationTitle("先生ギャラリー")
    }
}

#Preview {
    NavigationStack { AvatarGalleryView() }
}
