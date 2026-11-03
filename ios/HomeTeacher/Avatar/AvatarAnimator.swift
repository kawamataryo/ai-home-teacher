import Foundation
import RealityKit

/// 毎フレーム、状態に合わせてパーツの transform と目のテクスチャを動かす
@MainActor
final class AvatarAnimator {
    /// 状態が変わったときに前の姿勢から混ぜる秒数
    static let blendDuration: Double = 0.35

    private let model: TeacherModel
    /// 全体を上下させるための親（usdz のルートは Y-up 変換の回転を持っているので、その外側で動かす）
    let rig = Entity()
    private var baseTransforms: [TeacherPart: Transform] = [:]

    private(set) var state: AvatarState = .idle
    private var time: Double = 0
    private var stateStartedAt: Double = 0
    private var poseAtChange = AvatarPose()
    private var currentPose = AvatarPose()

    init(model: TeacherModel) {
        self.model = model
        rig.addChild(model.entity)
        for part in TeacherPart.allCases where part != .root {
            if let entity = model.part(part) {
                baseTransforms[part] = entity.transform
            }
        }
    }

    func setState(_ newState: AvatarState) {
        guard newState != state else { return }
        poseAtChange = currentPose
        state = newState
        stateStartedAt = time
    }

    func update(deltaTime: Double) {
        time += deltaTime
        let timeInState = time - stateStartedAt
        let target = AvatarPose.make(state: state, timeInState: timeInState, time: time)
        let k = min(1, timeInState / Self.blendDuration)
        let eased = Float(k * k * (3 - 2 * k))
        currentPose = k >= 1 ? target : AvatarPose.blend(poseAtChange, target, eased)
        apply(currentPose)
    }

    private func apply(_ pose: AvatarPose) {
        for (part, base) in baseTransforms {
            guard let entity = model.part(part) else { continue }
            let joint = pose.joint(part)
            var transform = base
            transform.rotation = base.rotation * joint.rotation
            transform.translation = base.translation + joint.offset
            entity.transform = transform
        }
        rig.position.y = pose.lift
        model.setEyes(pose.eyes)
    }
}
