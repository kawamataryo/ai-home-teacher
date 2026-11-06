import Foundation
import RealityKit
import simd

enum RiggedModelError: Error, Equatable {
    /// 骨かシェイプキーの入ったエンティティが見つからない
    case notRigged(String)
}

/// 骨とシェイプキーを持つ usdz（`avatar/rig_common.py` で書き出す）。
///
/// 骨の名前は `root/body/head` のようなパス。骨の値は親からの相対で、向きは骨ごとに違うので、
/// キャラの座標で書いた回転（`RigPose`）を休止姿勢から計算して骨のローカルに直す。
/// 読み込んだルートの Y-up の回転は消さず、向きと位置は外側の親で動かす。
@MainActor
final class RiggedModel: MouthTarget {
    /// usdz を読み込んだときのいちばん上のエンティティ
    let entity: Entity
    /// 骨とシェイプキーの部品を持つエンティティ
    private let target: Entity
    /// usdz の中の順の骨の名前
    private let jointOrder: [String]
    private let restJoints: [String: Transform]
    /// 骨の名前 → パス
    private let bonePaths: [RigBone: String]
    /// 休止姿勢での、骨のキャラの座標での回転
    private let restWorldRotations: [String: simd_quatf]
    /// いまの口（`RiggedAnimator` が読んで混ぜる）
    private(set) var mouth: MouthShape = .closed
    /// 同梱のモデルにあるシェイプキー
    let shapeNames: Set<String>

    init(entity: Entity) throws {
        self.entity = entity
        guard let target = Self.findRiggedEntity(under: entity),
              let pose = target.components[SkeletalPosesComponent.self]?.poses.default,
              let weights = target.components[BlendShapeWeightsComponent.self]
        else {
            throw RiggedModelError.notRigged(entity.name)
        }
        self.target = target
        jointOrder = pose.jointNames
        var rest: [String: Transform] = [:]
        for (index, name) in pose.jointNames.enumerated() {
            rest[name] = pose.jointTransforms[index]
        }
        restJoints = rest
        bonePaths = Self.bonePaths(pose.jointNames)
        restWorldRotations = Self.worldRotations(rest)
        var names = Set<String>()
        for data in weights.weightSet { names.formUnion(data.weightNames) }
        shapeNames = names
    }

    /// アプリに同梱した usdz を読み込む
    static func load(name: String, bundle: Bundle = .main) async throws -> RiggedModel {
        let entity = try await Entity(named: name, in: bundle)
        return try RiggedModel(entity: entity)
    }

    /// パスの最後の名前を `RigBone` に当てはめる
    nonisolated static func bonePaths(_ names: [String]) -> [RigBone: String] {
        var result: [RigBone: String] = [:]
        for name in names {
            let last = name.split(separator: "/").last.map(String.init) ?? name
            if let bone = RigBone(rawValue: last) { result[bone] = name }
        }
        return result
    }

    /// 親をたどって、骨ごとのキャラの座標での回転を計算する
    nonisolated static func worldRotations(_ rest: [String: Transform]) -> [String: simd_quatf] {
        var result: [String: simd_quatf] = [:]
        for name in rest.keys.sorted(by: { $0.count < $1.count }) {
            let local = rest[name]?.rotation ?? simd_quatf(angle: 0, axis: [1, 0, 0])
            let parent = name.split(separator: "/").dropLast().joined(separator: "/")
            result[name] = (result[parent] ?? simd_quatf(angle: 0, axis: [1, 0, 0])) * local
        }
        return result
    }

    /// キャラの座標での回転 `q` を、骨のローカルの回転にする（L' = L × W⁻¹ q W）
    nonisolated static func localRotation(rest: simd_quatf, world: simd_quatf, delta q: simd_quatf) -> simd_quatf {
        rest * (world.inverse * q * world)
    }

    var missingBones: [RigBone] {
        RigBone.allCases.filter { bonePaths[$0] == nil }
    }

    func setMouth(_ shape: MouthShape) {
        mouth = shape
    }

    /// 姿勢とシェイプキーを書き込む
    func apply(_ pose: RigPose, shapeWeights: [String: Float]) {
        guard var poses = target.components[SkeletalPosesComponent.self],
              var skeletal = poses.poses.default else { return }
        for (bone, q) in pose.rotations {
            guard let path = bonePaths[bone], var transform = restJoints[path], let world = restWorldRotations[path] else { continue }
            transform.rotation = Self.localRotation(rest: transform.rotation, world: world, delta: q)
            skeletal[path] = transform
        }
        if let path = bonePaths[.root], var transform = restJoints[path] {
            if let q = pose.rotations[.root], let world = restWorldRotations[path] {
                transform.rotation = Self.localRotation(rest: transform.rotation, world: world, delta: q)
            }
            transform.scale = transform.scale * RigPose.squashScale(pose.squash)
            skeletal[path] = transform
        }
        poses.poses.default = skeletal
        target.components.set(poses)

        guard var weights = target.components[BlendShapeWeightsComponent.self] else { return }
        for var data in Array(weights.weightSet) {
            var values = data.weights
            for (index, name) in data.weightNames.enumerated() {
                values[index] = shapeWeights[name] ?? 0
            }
            data.weights = values
            weights.weightSet.set(data)
        }
        target.components.set(weights)
    }

    private static func findRiggedEntity(under entity: Entity) -> Entity? {
        if entity.components.has(SkeletalPosesComponent.self), entity.components.has(BlendShapeWeightsComponent.self) {
            return entity
        }
        for child in entity.children {
            if let found = findRiggedEntity(under: child) { return found }
        }
        return nil
    }
}

/// 毎フレーム、状態に合わせて骨とシェイプキーを動かす
@MainActor
final class RiggedAnimator {
    static let blendDuration: Double = 0.3
    /// 口のシェイプキーが追いつく速さ（1 秒あたり。文字の切り替わりより少し速く）
    static let mouthSpeed: Float = 22

    private let model: RiggedModel
    /// 全体を動かす親（usdz のルートは Y-up の回転を持っているので、その外側で動かす）
    let rig = Entity()

    private(set) var state: AvatarState = .idle
    var lipSync: LipSyncPlayer? {
        didSet { lipSync?.model = model }
    }
    var mouthOverride: MouthShape?
    var targetYaw: Float = 0
    private var yaw: Float = 0
    private var time: Double = 0
    private var stateStartedAt: Double = 0
    private var poseAtChange = RigPose()
    private var currentPose = RigPose()
    private var mouthWeights: [RigShape: Float] = [:]

    private var scheduler: MannerismScheduler
    private var seenTouches = 0
    private var idleMouth: MouthShape?

    init(model: RiggedModel, mannerisms: MannerismSet = MannerismSet()) {
        self.model = model
        scheduler = MannerismScheduler(set: mannerisms)
        rig.addChild(model.entity)
    }

    /// 触った回数が増えていたら、短く反応する。姿勢に重ねるだけで、状態と口には触らない
    func receiveTouches(_ count: Int) {
        guard count != seenTouches else { return }
        seenTouches = count
        scheduler.touch(time: time)
    }

    /// 反応している動き（テスト用）
    var activeMannerism: MannerismKind? { scheduler.active?.kind }

    func setState(_ newState: AvatarState) {
        guard newState != state else { return }
        poseAtChange = currentPose
        state = newState
        stateStartedAt = time
    }

    func update(deltaTime: Double) {
        time += deltaTime
        let timeInState = time - stateStartedAt
        let target = RigPose.make(state: state, timeInState: timeInState, time: time)
        let k = min(1, timeInState / Self.blendDuration)
        let eased = Float(k * k * (3 - 2 * k))
        currentPose = k >= 1 ? target : RigPose.blend(poseAtChange, target, eased)
        idleMouth = nil
        if let overlay = scheduler.stateOverlay(for: state) {
            overlay.apply(elapsed: timeInState.truncatingRemainder(dividingBy: overlay.duration), to: &currentPose)
        }
        if let forced = MannerismDemo.forcedKind {
            idleMouth = forced.apply(elapsed: time.truncatingRemainder(dividingBy: forced.duration + 1), to: &currentPose)
        } else if let active = scheduler.update(state: state, time: time) {
            idleMouth = active.kind.apply(elapsed: time - active.startedAt, to: &currentPose)
        }
        yaw += (targetYaw - yaw) * Float(min(1, deltaTime * 5))
        rig.orientation = simd_quatf(angle: yaw, axis: [0, 1, 0])
        rig.position.y = currentPose.lift

        if let mouthOverride {
            model.setMouth(mouthOverride)
        } else if let idleMouth {
            model.setMouth(idleMouth)
        } else if let lipSync {
            lipSync.update()
        } else {
            model.setMouth(.closed)
        }
        advanceMouth(deltaTime: deltaTime)

        var weights: [String: Float] = [:]
        for (shape, value) in currentPose.shapes { weights[shape.rawValue] = value }
        for (shape, value) in mouthWeights { weights[shape.rawValue] = value }
        model.apply(currentPose, shapeWeights: weights)
    }

    private func advanceMouth(deltaTime: Double) {
        let wanted = RigShape.shape(for: model.mouth)
        let step = min(1, Self.mouthSpeed * Float(deltaTime))
        for shape in [RigShape.mouthA, .mouthI, .mouthU, .mouthE, .mouthO, .mouthN] {
            let goal: Float = shape == wanted ? 1 : 0
            let value = mouthWeights[shape] ?? 0
            mouthWeights[shape] = value + (goal - value) * step
        }
    }
}
