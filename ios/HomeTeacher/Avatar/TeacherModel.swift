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

    var textureName: String { textureName(prefix: "face") }
    func textureName(prefix: String) -> String { "\(prefix)_eyes_\(rawValue)" }
}

/// 読み込んだ先生のモデル。パーツの取り出しと顔テクスチャの差し替えを受け持つ。
@MainActor
final class TeacherModel: MouthTarget {
    /// usdz を読み込んだときのいちばん上のエンティティ
    let entity: Entity
    private var parts: [TeacherPart: Entity] = [:]
    private var textures: [String: TextureResource] = [:]
    /// 顔のテクスチャの名前の頭（`face` なら face_eyes_open.png）
    private let faceTextures: String
    /// 顔のテクスチャを光らせる（ロボの LED）
    private let glowingFace: Bool
    /// いま貼っているテクスチャ（毎フレーム呼ばれても同じなら差し替えない）
    private var currentTextures: [TeacherPart: String] = [:]

    init(entity: Entity, faceTextures: String = "face", glowingFace: Bool = false) {
        self.entity = entity
        self.faceTextures = faceTextures
        self.glowingFace = glowingFace
        for part in TeacherPart.allCases {
            parts[part] = entity.name == part.rawValue ? entity : entity.findEntity(named: part.rawValue)
        }
    }

    /// アプリに同梱した usdz を読み込む（既定は今の先生の teacher.usdz）
    static func load(name: String = "teacher", faceTextures: String = "face", glowingFace: Bool = false, bundle: Bundle = .main) async throws -> TeacherModel {
        let entity = try await Entity(named: name, in: bundle)
        return TeacherModel(entity: entity, faceTextures: faceTextures, glowingFace: glowingFace)
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
        let names = EyeShape.allCases.map { $0.textureName(prefix: faceTextures) } + MouthShape.allCases.map { $0.textureName(prefix: faceTextures) }
        for name in names where textures[name] == nil {
            textures[name] = try await TextureResource(named: name, in: bundle)
        }
    }

    func setEyes(_ shape: EyeShape) {
        setFaceTexture(shape.textureName(prefix: faceTextures), on: .eyes)
    }

    func setMouth(_ shape: MouthShape) {
        setFaceTexture(shape.textureName(prefix: faceTextures), on: .mouth)
    }

    private func setFaceTexture(_ name: String, on target: TeacherPart) {
        guard currentTextures[target] != name,
              let texture = textures[name], let entity = part(target) else { return }
        currentTextures[target] = name
        for model in Self.modelEntities(under: entity) {
            guard var component = model.components[ModelComponent.self] else { continue }
            if glowingFace {
                // LED の画面：光の当たり方に左右されず、テクスチャの色のまま見せる
                var screen = UnlitMaterial()
                screen.color = .init(tint: .white, texture: .init(texture))
                component.materials = [screen]
                model.components.set(component)
                continue
            }
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
