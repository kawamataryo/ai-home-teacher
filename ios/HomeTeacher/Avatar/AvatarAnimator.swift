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
    /// 口パク。つながっていれば毎フレーム口のテクスチャを差し替える
    var lipSync: LipSyncPlayer? {
        didSet { lipSync?.model = model }
    }
    /// 確認用に口の形を固定する（口パクより優先）
    var mouthOverride: MouthShape?
    /// 体の向き（ラジアン、上から見て反時計回り）。黒板の方を向くときに使う。少しずつ近づける（#105）
    var targetYaw: Float = 0
    private var yaw: Float = 0
    private var time: Double = 0
    private var stateStartedAt: Double = 0
    private var poseAtChange = AvatarPose()
    private var currentPose = AvatarPose()
    /// 待機中の癖で口を変えるとき（あくび）
    private var idleMouth: MouthShape?

    private var scheduler: MannerismScheduler
    private var seenTouches = 0

    init(model: TeacherModel, mannerisms: MannerismSet = .haru) {
        self.model = model
        scheduler = MannerismScheduler(set: mannerisms)
        rig.addChild(model.entity)
        for part in TeacherPart.allCases where part != .root {
            if let entity = model.part(part) {
                baseTransforms[part] = entity.transform
            }
        }
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
        let target = AvatarPose.make(state: state, timeInState: timeInState, time: time)
        let k = min(1, timeInState / Self.blendDuration)
        let eased = Float(k * k * (3 - 2 * k))
        currentPose = k >= 1 ? target : AvatarPose.blend(poseAtChange, target, eased)
        idleMouth = nil
        if let overlay = scheduler.stateOverlay(for: state) {
            overlay.apply(elapsed: timeInState.truncatingRemainder(dividingBy: overlay.duration), to: &currentPose)
        }
        if let forced = MannerismDemo.forcedKind {
            idleMouth = forced.apply(elapsed: time.truncatingRemainder(dividingBy: forced.duration + 1), to: &currentPose)
        } else if let active = scheduler.update(state: state, time: time) {
            idleMouth = active.kind.apply(elapsed: time - active.startedAt, to: &currentPose)
        }
        // 体の向きは 0.3 秒くらいで追いつく
        yaw += (targetYaw - yaw) * Float(min(1, deltaTime * 5))
        rig.orientation = simd_quatf(angle: yaw, axis: [0, 1, 0])
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
        if let mouthOverride {
            model.setMouth(mouthOverride)
        } else if let idleMouth {
            model.setMouth(idleMouth)
        } else if let lipSync {
            // 選ぶ画面と学習の画面で同じ口パクを使うので、つなぎ先に頼らず自分のモデルに入れる
            model.setMouth(lipSync.update())
        } else {
            model.setMouth(.closed)
        }
    }
}
