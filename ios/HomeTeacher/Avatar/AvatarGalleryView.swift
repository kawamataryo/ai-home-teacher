import SwiftUI

/// デバッグ用: 先生のモデルと顔テクスチャを確認する画面
struct AvatarGalleryView: View {
    @State private var mouth = "face_mouth_closed"
    @State private var eyes: EyeShape = .open

    var body: some View {
        VStack {
            AvatarView(mouthTextureName: mouth, eyes: eyes)
            Picker("口", selection: $mouth) {
                ForEach(TeacherModel.mouthTextureNames, id: \.self) { name in
                    Text(name.replacingOccurrences(of: "face_mouth_", with: "")).tag(name)
                }
            }
            .pickerStyle(.segmented)
            Picker("目", selection: $eyes) {
                ForEach(EyeShape.allCases, id: \.self) { shape in
                    Text(shape.rawValue).tag(shape)
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
