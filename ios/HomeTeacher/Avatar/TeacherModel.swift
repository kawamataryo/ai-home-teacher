import Foundation
import RealityKit

/// teacher.usdz のパーツ名。avatar/build_teacher.py のオブジェクト名と合わせる。
///
/// 各パーツの原点は関節（脚 = 股関節、腕 = 肩、頭 = 首、胴体 = 腰）。
/// パーツのローカル座標は Blender のまま（上 = +Z、正面 = -Y、キャラの左 = +X）。
enum TeacherPart: String, CaseIterable, Sendable {
    case root = "Teacher"
    case body = "Body"
    case head = "Head"
    case armL = "ArmL"
    case armR = "ArmR"
    case legL = "LegL"
    case legR = "LegR"
    case eyes = "Eyes"
    case mouth = "Mouth"
    case glasses = "Glasses"
}

/// 目のテクスチャ（Resources/Teacher/face_eyes_*.png）
enum EyeShape: String, CaseIterable, Sendable {
    case open
    case closed
    case happy

    var textureName: String { "face_eyes_\(rawValue)" }
}

/// 読み込んだ先生のモデル。パーツの取り出しと顔テクスチャの差し替えを受け持つ。
@MainActor
final class TeacherModel {
    /// usdz を読み込んだときのいちばん上のエンティティ
    let entity: Entity
    private var parts: [TeacherPart: Entity] = [:]
    private var textures: [String: TextureResource] = [:]

    init(entity: Entity) {
        self.entity = entity
        for part in TeacherPart.allCases {
            parts[part] = entity.name == part.rawValue ? entity : entity.findEntity(named: part.rawValue)
        }
    }

    /// アプリに同梱した teacher.usdz を読み込む
    static func load(bundle: Bundle = .main) async throws -> TeacherModel {
        let entity = try await Entity(named: "teacher", in: bundle)
        return TeacherModel(entity: entity)
    }

    func part(_ part: TeacherPart) -> Entity? {
        parts[part]
    }

    /// 見つからなかったパーツ（usdz とコードの食い違いの確認用）
    var missingParts: [TeacherPart] {
        TeacherPart.allCases.filter { parts[$0] == nil }
    }

    /// 顔テクスチャを先に読み込んでおく（差し替えのたびに読み込まないように）
    func preloadFaceTextures(bundle: Bundle = .main) async throws {
        let names = EyeShape.allCases.map(\.textureName) + Self.mouthTextureNames
        for name in names where textures[name] == nil {
            textures[name] = try await TextureResource(named: name, in: bundle)
        }
    }

    func setEyes(_ shape: EyeShape) {
        setFaceTexture(shape.textureName, on: .eyes)
    }

    /// 口のテクスチャを差し替える。名前は face_mouth_<a|i|u|e|o|n|closed>
    func setMouthTexture(named name: String) {
        setFaceTexture(name, on: .mouth)
    }

    static let mouthTextureNames = ["a", "i", "u", "e", "o", "n", "closed"].map { "face_mouth_\($0)" }

    private func setFaceTexture(_ name: String, on target: TeacherPart) {
        guard let texture = textures[name], let entity = part(target) else { return }
        for model in Self.modelEntities(under: entity) {
            guard var component = model.components[ModelComponent.self] else { continue }
            // usdz のマテリアルをそのまま使い、テクスチャだけ替える（頭の肌と同じ光の当たり方にするため）
            var material = component.materials.first as? PhysicallyBasedMaterial ?? PhysicallyBasedMaterial()
            material.baseColor = .init(tint: .white, texture: .init(texture))
            component.materials = [material]
            model.components.set(component)
        }
    }

    private static func modelEntities(under entity: Entity) -> [Entity] {
        var result: [Entity] = []
        if entity.components.has(ModelComponent.self) { result.append(entity) }
        for child in entity.children {
            result += modelEntities(under: child)
        }
        return result
    }
}
