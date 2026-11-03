import Foundation
import simd

/// ある瞬間の先生の姿勢。各パーツの回転と移動（モデルの基本姿勢からの差分）
///
/// パーツのローカル座標は Blender のまま（上 = +Z、正面 = -Y、キャラの左 = +X）なので:
/// - X 軸まわり（pitch）: 正で前に倒れる（頭ならうつむく）。腕は負で前に上がる
/// - Y 軸まわり（roll）: 首かしげ。左腕（ArmL）は負、右腕（ArmR）は正で横に上がる
/// - Z 軸まわり（yaw）: 振り向き
struct AvatarPose: Sendable {
    struct Joint: Sendable {
        var rotation = simd_quatf(angle: 0, axis: [1, 0, 0])
        var offset = SIMD3<Float>(repeating: 0)
    }

    var joints: [TeacherPart: Joint] = [:]
    /// 全体の上下（ジャンプ）。RealityKit の座標（Y-up、メートル）
    var lift: Float = 0
    var eyes: EyeShape = .open

    func joint(_ part: TeacherPart) -> Joint {
        joints[part] ?? Joint()
    }

    /// 2 つの姿勢を混ぜる（状態が変わったときになめらかにつなぐ）
    static func blend(_ a: AvatarPose, _ b: AvatarPose, _ t: Float) -> AvatarPose {
        var result = AvatarPose()
        let parts = Set(a.joints.keys).union(b.joints.keys)
        for part in parts {
            let ja = a.joint(part)
            let jb = b.joint(part)
            result.joints[part] = Joint(
                rotation: simd_slerp(ja.rotation, jb.rotation, t),
                offset: simd_mix(ja.offset, jb.offset, SIMD3(repeating: t))
            )
        }
        result.lift = a.lift + (b.lift - a.lift) * t
        result.eyes = t < 0.5 ? a.eyes : b.eyes
        return result
    }
}

extension AvatarPose {
    /// 状態ごとの動き。`timeInState` は状態に入ってからの秒数、`time` は通しの秒数（揺れ・まばたき用）
    static func make(state: AvatarState, timeInState t: Double, time g: Double) -> AvatarPose {
        var pose = AvatarPose()
        let s = { (x: Double) in Float(sin(x)) }

        // どの状態でも少しだけ体が揺れる
        pose.set(.body, roll: 0.025 * s(g * 1.3))
        pose.set(.head, roll: -0.03 * s(g * 1.3 + 0.6))
        pose.eyes = isBlinking(at: g) ? .closed : .open

        switch state {
        case .idle:
            pose.set(.armL, pitch: 0.05 * s(g * 1.3), roll: -0.06)
            pose.set(.armR, pitch: -0.05 * s(g * 1.3), roll: 0.06)

        case .listening:
            // うなずき（1.2 秒に 1 回）と少し前のめり
            let nod = Float(0.5 - 0.5 * cos(t * 2 * .pi / 1.2))
            pose.set(.head, pitch: 0.06 + 0.2 * nod, roll: -0.04)
            pose.set(.body, pitch: 0.06)
            pose.set(.armL, roll: -0.05)
            pose.set(.armR, roll: 0.05)

        case .thinking:
            // 首をかしげて、右手をあごへ
            pose.set(.head, pitch: -0.08, roll: 0.26 + 0.03 * s(g * 1.5))
            pose.set(.armR, pitch: -2.3, roll: 1.3)
            pose.set(.armL, roll: -0.05)
            pose.set(.body, roll: -0.04)

        case .looking:
            // ノート（手前の下）をのぞきこむ
            pose.set(.head, pitch: 0.42 + 0.03 * s(t * 1.7))
            pose.set(.body, pitch: 0.12)
            pose.set(.armL, pitch: -0.35, roll: -0.05)
            pose.set(.armR, pitch: -0.35, roll: 0.05)

        case .talking:
            pose.set(.head, pitch: 0.05 * s(g * 4.2), roll: 0.05 * s(g * 2.1))
            pose.set(.armL, pitch: -0.45 - 0.2 * s(g * 2.3), roll: -0.1)
            pose.set(.armR, pitch: -0.25 - 0.15 * s(g * 2.9 + 1), roll: 0.1)

        case .praise:
            // ぴょんぴょん跳んで、両手を上げて喜ぶ
            let hop = abs(sin(t * .pi * 1.6))
            pose.lift = Float(0.07 * hop)
            pose.set(.armL, roll: -2.45 + 0.2 * s(t * 10))
            pose.set(.armR, roll: 2.45 - 0.2 * s(t * 10))
            pose.set(.legL, pitch: Float(-0.15 * hop))
            pose.set(.legR, pitch: Float(-0.15 * hop))
            pose.set(.head, pitch: -0.1, roll: 0.06 * s(t * 5))
            pose.eyes = .happy

        case .encourage:
            // 右手のこぶしを上げて「がんばれ！」
            let pump = s(t * 7)
            pose.set(.armR, pitch: -0.4, roll: 2.55 + 0.25 * pump)
            pose.set(.armL, pitch: -1.3, roll: -0.25)
            pose.set(.head, pitch: 0.04 * pump, roll: -0.05)
            pose.set(.body, pitch: -0.03)
            pose.lift = Float(0.015 * (1 + Double(pump)))

        case .break:
            // 6 秒ごとにぐーっと伸びをする
            let stretch = Float(0.5 - 0.5 * cos(t * 2 * .pi / 6))
            pose.set(.armL, roll: -0.06 - 2.85 * stretch)
            pose.set(.armR, roll: 0.06 + 2.85 * stretch)
            pose.set(.head, pitch: -0.25 * stretch)
            pose.set(.body, pitch: -0.07 * stretch)
            pose.lift = 0.02 * stretch
            if stretch > 0.7 { pose.eyes = .closed }
        }
        return pose
    }

    /// 3.7 秒に 1 回、0.13 秒だけ目を閉じる
    static func isBlinking(at time: Double) -> Bool {
        time.truncatingRemainder(dividingBy: 3.7) > 3.57
    }

    /// X（pitch）→ Y（roll）→ Z（yaw）の順に回す
    mutating func set(_ part: TeacherPart, pitch: Float = 0, roll: Float = 0, yaw: Float = 0) {
        let q = simd_quatf(angle: yaw, axis: [0, 0, 1])
            * simd_quatf(angle: roll, axis: [0, 1, 0])
            * simd_quatf(angle: pitch, axis: [1, 0, 0])
        joints[part, default: Joint()].rotation = q
    }
}
