import Foundation
import simd

/// 骨の名前。Blender のスクリプト（`avatar/rig_common.py`）の骨の名前と合わせる。ないキャラの骨は無視する
enum RigBone: String, CaseIterable, Sendable {
    case root, body, head, armL, armR, legL, legR, earL, earR, tail
}

/// シェイプキーの名前。`avatar/rig_common.py` と合わせる
enum RigShape: String, CaseIterable, Sendable {
    case mouthA = "mouth_a"
    case mouthI = "mouth_i"
    case mouthU = "mouth_u"
    case mouthE = "mouth_e"
    case mouthO = "mouth_o"
    case mouthN = "mouth_n"
    case eyeBlink = "eye_blink"
    case eyeHappy = "eye_happy"
    case browWorry = "brow_worry"

    /// 口の形に対応するシェイプキー。閉じた口はどれも使わない
    static func shape(for mouth: MouthShape) -> RigShape? {
        switch mouth {
        case .a: .mouthA
        case .i: .mouthI
        case .u: .mouthU
        case .e: .mouthE
        case .o: .mouthO
        case .n: .mouthN
        case .closed: nil
        }
    }
}

/// 骨とシェイプキーで動かすキャラの、ある瞬間の姿勢（口は別。`RiggedAnimator` が混ぜる）。
///
/// 回転はキャラの座標（Blender のまま：上 = +Z、正面 = -Y、キャラの左 = +X）で書く。骨ごとの向きは `RiggedModel` が吸収する。
/// - X 軸まわり（pitch）: 正で前に倒れる
/// - Y 軸まわり（roll）: 首かしげ。左腕（armL）は負、右腕（armR）は正で横に上がる
/// - Z 軸まわり（yaw）: 振り向き
struct RigPose: Sendable, Equatable {
    var rotations: [RigBone: simd_quatf] = [:]
    /// 全体の上下（ジャンプ）。RealityKit の座標（Y-up、メートル）
    var lift: Float = 0
    /// つぶれと伸び。1 がふつう、小さいとつぶれ、大きいと伸びる（体積を保つように横に広がる）
    var squash: Float = 1
    var shapes: [RigShape: Float] = [:]

    mutating func set(_ bone: RigBone, pitch: Float = 0, roll: Float = 0, yaw: Float = 0) {
        rotations[bone] = simd_quatf(angle: yaw, axis: [0, 0, 1])
            * simd_quatf(angle: roll, axis: [0, 1, 0])
            * simd_quatf(angle: pitch, axis: [1, 0, 0])
    }

    func rotation(_ bone: RigBone) -> simd_quatf {
        rotations[bone] ?? simd_quatf(angle: 0, axis: [1, 0, 0])
    }

    /// 2 つの姿勢を混ぜる（状態が変わったときになめらかにつなぐ）
    static func blend(_ a: RigPose, _ b: RigPose, _ t: Float) -> RigPose {
        var result = RigPose()
        for bone in Set(a.rotations.keys).union(b.rotations.keys) {
            result.rotations[bone] = simd_slerp(a.rotation(bone), b.rotation(bone), t)
        }
        for shape in Set(a.shapes.keys).union(b.shapes.keys) {
            let x = a.shapes[shape] ?? 0
            result.shapes[shape] = x + ((b.shapes[shape] ?? 0) - x) * t
        }
        result.lift = a.lift + (b.lift - a.lift) * t
        result.squash = a.squash + (b.squash - a.squash) * t
        return result
    }

    /// つぶれと伸びの骨のスケール（骨の向き = 上）。体積を保つ
    static func squashScale(_ squash: Float) -> SIMD3<Float> {
        let s = max(squash, 0.01)
        let side = 1 / s.squareRoot()
        return [side, s, side]
    }
}

extension RigPose {
    /// 状態ごとの動き。`timeInState` は状態に入ってからの秒数、`time` は通しの秒数（揺れ・まばたき用）
    static func make(state: AvatarState, timeInState t: Double, time g: Double) -> RigPose {
        var pose = RigPose()
        let s = { (x: Double) in Float(sin(x)) }

        // どの状態でも、息をするように少し動く
        pose.squash = 1 + 0.012 * s(g * 2.1)
        pose.set(.head, roll: 0.03 * s(g * 1.3 + 0.6))
        pose.shapes[.eyeBlink] = AvatarPose.isBlinking(at: g) ? 1 : 0

        switch state {
        case .idle:
            pose.set(.armL, pitch: 0.06 * s(g * 1.3), roll: -0.1)
            pose.set(.armR, pitch: -0.06 * s(g * 1.3), roll: 0.1)
            pose.set(.earL, roll: -0.05 * s(g * 0.9))
            pose.set(.earR, roll: 0.05 * s(g * 0.9))
            pose.set(.tail, yaw: 0.15 * s(g * 1.2))

        case .listening:
            // うなずいて、耳を立てる
            let nod = Float(0.5 - 0.5 * cos(t * 2 * .pi / 1.2))
            pose.set(.head, pitch: 0.05 + 0.2 * nod, roll: -0.05)
            pose.set(.body, pitch: 0.07)
            pose.squash = 1 - 0.02 * nod
            pose.set(.earL, roll: 0.18)
            pose.set(.earR, roll: -0.18)
            pose.set(.tail, yaw: 0.25 * s(g * 2.2))

        case .thinking:
            // 首をかしげて、片手をあごへ。体もすこし傾く
            pose.set(.head, pitch: -0.08, roll: 0.3 + 0.03 * s(g * 1.5))
            pose.set(.body, roll: -0.06)
            pose.set(.armR, pitch: -1.6, roll: 0.5)
            pose.set(.armL, roll: -0.08)
            pose.set(.earL, roll: -0.2)
            pose.set(.earR, roll: -0.05)
            pose.shapes[.browWorry] = 0.35

        case .looking:
            // 前にのぞきこむ
            pose.set(.head, pitch: 0.42 + 0.03 * s(t * 1.7))
            pose.set(.body, pitch: 0.16)
            pose.set(.armL, pitch: -0.6, roll: -0.05)
            pose.set(.armR, pitch: -0.6, roll: 0.05)
            pose.set(.earL, pitch: 0.15)
            pose.set(.earR, pitch: 0.15)

        case .talking:
            pose.set(.head, pitch: 0.05 * s(g * 4.2), roll: 0.05 * s(g * 2.1))
            pose.set(.armL, pitch: -0.45 - 0.2 * s(g * 2.3), roll: -0.15)
            pose.set(.armR, pitch: -0.25 - 0.15 * s(g * 2.9 + 1), roll: 0.15)
            pose.squash = 1 + 0.015 * s(g * 4.2)
            pose.set(.tail, yaw: 0.12 * s(g * 1.6))

        case .praise:
            // はずんで喜ぶ：着地でつぶれ、飛ぶときに伸びる
            let phase = t * 1.6
            let hop = abs(sin(phase * .pi))
            pose.lift = Float(0.14 * hop)
            pose.squash = 1 + 0.16 * Float(hop) - 0.22 * Float(max(0, 1 - hop * 3.5))
            pose.set(.armL, roll: -2.3 + 0.25 * s(t * 10))
            pose.set(.armR, roll: 2.3 - 0.25 * s(t * 10))
            pose.set(.legL, pitch: Float(-0.25 * hop))
            pose.set(.legR, pitch: Float(0.25 * hop))
            pose.set(.head, pitch: -0.12, roll: 0.08 * s(t * 5))
            pose.set(.earL, roll: 0.25 * s(t * 11))
            pose.set(.earR, roll: -0.25 * s(t * 11))
            pose.set(.tail, yaw: 0.8 * s(t * 18))
            pose.shapes[.eyeHappy] = 1
            pose.shapes[.eyeBlink] = 0

        case .encourage:
            // 片手を上げて「がんばれ！」。小さくはずむ
            let pump = s(t * 7)
            pose.set(.armR, pitch: -0.3, roll: 2.3 + 0.3 * pump)
            pose.set(.armL, pitch: -1.2, roll: -0.25)
            pose.set(.head, pitch: 0.05 * pump, roll: -0.06)
            pose.set(.body, pitch: -0.04)
            pose.lift = Float(0.02 * (1 + Double(pump)))
            pose.squash = 1 - 0.04 * pump
            pose.set(.earL, roll: 0.12)
            pose.set(.earR, roll: -0.12)
            pose.set(.tail, yaw: 0.35 * s(t * 7))
            pose.shapes[.browWorry] = 0.25

        case .break:
            // 6 秒ごとにぐーっと伸びる
            let stretch = Float(0.5 - 0.5 * cos(t * 2 * .pi / 6))
            pose.squash = 1 + 0.14 * stretch
            pose.set(.armL, roll: -0.1 - 2.6 * stretch)
            pose.set(.armR, roll: 0.1 + 2.6 * stretch)
            pose.set(.head, pitch: -0.25 * stretch)
            pose.set(.body, pitch: -0.07 * stretch)
            pose.lift = 0.02 * stretch
            pose.set(.earL, roll: -0.15 * stretch)
            pose.set(.earR, roll: 0.15 * stretch)
            if stretch > 0.7 { pose.shapes[.eyeBlink] = 1 }
        }
        return pose
    }
}
