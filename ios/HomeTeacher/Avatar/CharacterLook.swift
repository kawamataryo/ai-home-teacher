import Foundation

/// キャラの見た目の形式と、使う素材（#121）。`prompts/characters/characters.json` の `look`
struct CharacterLook: Codable, Equatable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// パーツごとに動かす 3D（`avatar/build_teacher.py`）
        case voxel
        /// 骨とシェイプキーで動かす 3D（`avatar/rig_common.py`）
        case rigged
        /// 切り絵風の 2D（SwiftUI）
        case paper
        /// 黒板に描いた線画の 2D（SwiftUI）
        case chalk
    }

    var kind: Kind
    /// usdz の名前（3D のとき）
    var model: String?
    /// 顔のテクスチャの名前の頭（voxel のとき）
    var faceTextures: String?
    /// 顔のテクスチャが自分で光る（ロボの LED の画面。voxel のとき）
    var glowingFace: Bool?

    var modelName: String { model ?? "teacher" }
    var faceTexturePrefix: String { faceTextures ?? "face" }

    /// 既定の先生の見た目
    static let haru = CharacterLook(kind: .voxel, model: "teacher", faceTextures: "face")

    /// 起動引数 `-avatarLook rigged:proto_rig`（`voxel:<usdz>:<顔のテクスチャ>` / `paper` / `chalk`）。確認用
    static func fromLaunchArguments(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> CharacterLook? {
        guard let index = arguments.firstIndex(of: "-avatarLook"), index + 1 < arguments.count else { return nil }
        let parts = arguments[index + 1].split(separator: ":").map(String.init)
        guard let first = parts.first, let kind = Kind(rawValue: first) else { return nil }
        return CharacterLook(kind: kind, model: parts.count > 1 ? parts[1] : nil, faceTextures: parts.count > 2 ? parts[2] : nil)
    }
}
