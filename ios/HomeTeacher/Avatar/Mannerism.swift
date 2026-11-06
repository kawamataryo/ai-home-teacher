import Foundation
import simd

/// キャラの動きの癖（#122）。待機中にときどき出る癖、触ったときの反応、喜ぶ・応援するときの違いをこの一覧から選ぶ。
/// 声は出さない。動きは短く、小さくする（問題より先生に目が行く動きを続けない）。
enum MannerismKind: String, Codable, CaseIterable, Sendable {
    // 待機中の癖
    case glasses, yawn, lookAround, scratchHead, peerAtHand, calibrate, smileTry
    case poyo, earTwitch, tailWag, tailChase, pawLick, slowBlink, paperSlip, chalkFret
    // 触ったときの反応
    case startle, shyLean, giggle, squish, paperFlutter, chalkDodge, beep
    // 喜ぶ・応援するときに重ねる動き
    case clap, salute, wiggle, shyPraise, paperCheer, chalkCheer, nodPump

    /// 1 回の長さ（秒）。喜ぶ・応援するときはくり返す
    var duration: Double {
        switch self {
        case .glasses: 1.6
        case .yawn: 2.6
        case .lookAround: 2.6
        case .scratchHead: 1.8
        case .peerAtHand: 2.4
        case .calibrate: 1.8
        case .smileTry: 1.6
        case .poyo: 1.2
        case .earTwitch: 0.9
        case .tailWag: 1.6
        case .tailChase: 2.2
        case .pawLick: 2.2
        case .slowBlink: 1.6
        case .paperSlip: 1.8
        case .chalkFret: 2.0
        case .startle: 0.8
        case .shyLean: 1.3
        case .giggle: 1.1
        case .squish: 0.9
        case .paperFlutter: 1.0
        case .chalkDodge: 0.9
        case .beep: 0.9
        case .clap: 0.5
        case .salute: 1.2
        case .wiggle: 0.6
        case .shyPraise: 2.0
        case .paperCheer: 0.8
        case .chalkCheer: 0.9
        case .nodPump: 0.8
        }
    }
}

/// キャラの動きの癖の組。`prompts/characters/characters.json` の `mannerisms`
struct MannerismSet: Codable, Equatable, Sendable {
    /// 待機中にときどき出る癖
    var idle: [MannerismKind] = []
    /// 触ったときの反応
    var touch: MannerismKind = .startle
    /// 喜ぶときに重ねる動き。nil ならその形式の基本の喜び方だけ
    var praise: MannerismKind?
    /// 応援するときに重ねる動き
    var encourage: MannerismKind?

    /// 今の先生
    static let haru = MannerismSet(idle: [.glasses, .scratchHead, .yawn], touch: .startle)
}

/// 癖を出す先の部位。形式ごとの姿勢（`AvatarPose` / `RigPose` / `PaperPose`）に当てはめる
enum MannerismPart: Sendable {
    case head, body, armL, armR, legL, legR, earL, earR, tail
}

/// 癖の目の形
enum MannerismEyes: Sendable {
    case closed, happy
}

/// 癖を重ねる先。回転はキャラの座標の差分（ラジアン）で、もとの姿勢に重ねる
protocol MannerismTarget {
    mutating func bend(_ part: MannerismPart, pitch: Float, roll: Float, yaw: Float)
    mutating func raise(_ amount: Float)
    mutating func squash(_ amount: Float)
    mutating func setEyes(_ eyes: MannerismEyes)
    /// メガネなどの小物を少し動かす（ボクセルの先生だけ）
    mutating func nudgeAccessory(_ amount: Float)
}

extension MannerismTarget {
    mutating func bend(_ part: MannerismPart, pitch: Float = 0, roll: Float = 0, yaw: Float = 0) {
        bend(part, pitch: pitch, roll: roll, yaw: yaw)
    }

    mutating func nudgeAccessory(_ amount: Float) {}
}

extension MannerismKind {
    /// 出だしと終わりをなめらかにする（0〜1）
    static func envelope(_ progress: Double, edge: Double = 0.18) -> Float {
        let p = min(max(progress, 0), 1)
        let up = min(p / edge, 1)
        let down = min((1 - p) / edge, 1)
        let k = min(up, down)
        return Float(k * k * (3 - 2 * k))
    }

    /// `elapsed` 秒目の動きを `target` に重ねる。口の形を変えるときは返す（待機中のあくびだけ）
    @discardableResult
    func apply<T: MannerismTarget>(elapsed: Double, to target: inout T) -> MouthShape? {
        let d = duration
        let p = elapsed / d
        let e = Self.envelope(p)
        let s = { (x: Double) in Float(sin(x)) }
        let wave = s(elapsed * 2 * .pi / d)
        let smooth = { (x: Double) in x * x * (3 - 2 * x) }
        switch self {
        case .glasses:
            // メガネがずり落ちて、手を添えて、くいっと上げる
            target.bend(.armR, pitch: -1.9 * e, yaw: 0.35 * e)
            let slip = p < 0.45 ? smooth(p / 0.45) : (p < 0.6 ? 1 - smooth((p - 0.45) / 0.15) : 0)
            target.nudgeAccessory(-0.038 * Float(slip))
            target.bend(.head, pitch: 0.1 * e - 0.14 * Float(p > 0.45 && p < 0.7 ? sin((p - 0.45) / 0.25 * .pi) : 0))
        case .yawn:
            // あくびをこらえる：口に手を当てて、上を向いて目をつむる
            target.bend(.armL, pitch: -2.55 * e, yaw: -0.5 * e)
            target.bend(.head, pitch: -0.2 * e)
            target.squash(0.03 * e)
            if e > 0.6 { target.setEyes(.closed) }
            return e > 0.45 ? .o : nil
        case .lookAround:
            target.bend(.head, yaw: 0.32 * wave * e)
        case .scratchHead:
            target.bend(.armR, pitch: -0.25 * e, roll: 2.75 * e + 0.1 * s(elapsed * 22) * e)
            target.bend(.head, roll: -0.14 * e)
        case .peerAtHand:
            // 手のひらをのぞきこんで、ふしぎそうに見る
            target.bend(.armL, pitch: -1.4 * e, roll: -0.3 * e)
            target.bend(.head, pitch: 0.28 * e, roll: 0.1 * e, yaw: 0.2 * e)
        case .calibrate:
            // 首をカクッ、カクッと順に動かして調整する（ロボ）
            let step = (elapsed / d * 4).rounded(.down)
            let yaw: Float = [0.25, -0.25, 0.0, 0.0][min(Int(step), 3)]
            target.bend(.head, yaw: yaw * (p < 0.95 ? 1 : 0))
            target.bend(.armL, pitch: step == 1 ? -0.35 : 0)
        case .smileTry:
            // うまく笑えるか試す（ロボ）
            if p > 0.2 && p < 0.8 { target.setEyes(.happy) }
            target.bend(.head, roll: 0.1 * e)
        case .poyo:
            // むにっとつぶれて、ぽよんと戻る
            let bounce = Float(sin(elapsed * 2 * .pi / 0.55) * exp(-elapsed * 3.0))
            target.squash(0.14 * bounce)
        case .earTwitch:
            target.bend(.earL, roll: 0.45 * s(elapsed * 22) * e)
        case .tailWag:
            target.bend(.tail, yaw: 0.65 * s(elapsed * 12) * e)
        case .tailChase:
            // しっぽを見ようと、体をひねる
            target.bend(.body, yaw: 0.5 * wave * e)
            target.bend(.head, yaw: 0.35 * wave * e)
            target.bend(.tail, yaw: 0.7 * s(elapsed * 14) * e)
        case .pawLick:
            // 手を口元へ持っていく（ネコ）
            target.bend(.armR, pitch: -1.9 * e + 0.15 * s(elapsed * 14) * e, roll: 0.6 * e)
            target.bend(.head, pitch: 0.16 * e, roll: 0.1 * e)
            if e > 0.5 { target.setEyes(.closed) }
        case .slowBlink:
            // ゆっくり目を閉じて開ける（ネコ）
            if p > 0.3 && p < 0.7 { target.setEyes(.closed) }
            target.bend(.head, pitch: 0.05 * e)
        case .paperSlip:
            // 紙の姿勢がくずれて、あわてて直す
            let slip = p < 0.45 ? Float(p / 0.45) : Float(max(0, 1 - (p - 0.45) / 0.2))
            target.bend(.body, roll: 0.32 * slip)
            target.bend(.head, roll: -0.25 * slip)
            target.bend(.armR, roll: 0.7 * slip)
        case .chalkFret:
            // 自分の腕（チョーク）の短さを見て気にする
            target.bend(.armR, pitch: -0.6 * e)
            target.bend(.head, pitch: 0.2 * e, roll: 0.14 * e)
        case .startle:
            // びくっとして、少しはねる
            target.raise(0.045 * e)
            target.squash(0.05 * e)
            target.bend(.armL, roll: -0.7 * e)
            target.bend(.armR, roll: 0.7 * e)
            target.bend(.head, pitch: -0.12 * e)
        case .shyLean:
            target.bend(.head, roll: 0.22 * e, yaw: 0.2 * e)
            target.bend(.body, roll: -0.05 * e)
            target.bend(.tail, yaw: 0.4 * s(elapsed * 8) * e)
            if e > 0.5 { target.setEyes(.happy) }
        case .giggle:
            target.bend(.body, roll: 0.1 * s(elapsed * 16) * e)
            target.bend(.head, roll: 0.12 * s(elapsed * 16 + 1) * e)
            target.setEyes(.happy)
        case .squish:
            let bounce = Float(sin(elapsed * 2 * .pi / 0.45) * exp(-elapsed * 3.5))
            target.squash(-0.22 * bounce)
            if p < 0.5 { target.setEyes(.closed) }
        case .paperFlutter:
            target.bend(.body, roll: 0.16 * s(elapsed * 24) * e)
            target.bend(.armL, roll: -0.5 * s(elapsed * 18) * e)
            target.bend(.armR, roll: 0.5 * s(elapsed * 18 + 1) * e)
        case .chalkDodge:
            // 消されそうになって、よける
            target.bend(.body, roll: -0.3 * e)
            target.raise(0.03 * e)
            target.setEyes(.closed)
        case .beep:
            target.bend(.head, yaw: (p * 6).rounded(.down).truncatingRemainder(dividingBy: 2) == 0 ? 0.14 * e : -0.14 * e)
            target.bend(.armL, roll: -0.35 * e)
        case .clap:
            // 胸の前で手をたたく
            let beat = Float(0.5 + 0.5 * sin(elapsed * 2 * .pi / d))
            target.bend(.armL, pitch: -1.2, roll: 1.9 + 0.3 * beat)
            target.bend(.armR, pitch: -1.2, roll: -1.9 - 0.3 * beat)
        case .salute:
            // カクッと敬礼する（ロボ）
            target.bend(.armR, pitch: -1.0, roll: -1.4)
            target.bend(.head, roll: (p * 4).rounded(.down).truncatingRemainder(dividingBy: 2) == 0 ? 0.08 : -0.08)
        case .wiggle:
            // 全身でよろこぶ（子犬）
            target.bend(.body, roll: 0.18 * wave)
            target.bend(.tail, yaw: 0.9 * s(elapsed * 26))
            target.bend(.earL, roll: 0.3 * s(elapsed * 16))
            target.bend(.earR, roll: -0.3 * s(elapsed * 16))
        case .shyPraise:
            // 照れて目をそらす（ネコ）
            target.bend(.head, roll: 0.2, yaw: 0.28)
            target.bend(.tail, yaw: 0.3 * wave)
        case .paperCheer:
            target.bend(.body, roll: 0.14 * wave)
        case .chalkCheer:
            target.bend(.body, roll: 0.12 * wave)
            target.raise(0.02 * abs(wave))
        case .nodPump:
            target.bend(.head, pitch: 0.14 * wave)
        }
        return nil
    }
}

/// 癖をいつ出すかを決める。待機中だけ、間隔を空けてランダムに、続けて同じものを出さない。
/// 触った反応はどの状態でも短く出すが、会話の状態にも音声にも触らない（この型は姿勢に重ねる動きを選ぶだけ）。
struct MannerismScheduler: Sendable {
    /// 待機になってから最初の癖までと、癖と癖の間の秒数
    static let intervalRange: ClosedRange<Double> = 18...42
    /// 触った反応のあと、次に反応するまでの秒数（連打で動き続けない）
    static let touchCooldown: Double = 0.5

    struct Active: Equatable, Sendable {
        var kind: MannerismKind
        var startedAt: Double
    }

    let set: MannerismSet
    private(set) var active: Active?
    private(set) var lastIdleKind: MannerismKind?
    private var nextIdleAt: Double?
    private var touchReadyAt: Double = 0
    private var isTouchActive = false
    private var generator: SplitMixGenerator

    init(set: MannerismSet, seed: UInt64 = UInt64.random(in: .min ... .max)) {
        self.set = set
        generator = SplitMixGenerator(state: seed)
    }

    /// 毎フレーム呼ぶ。いま重ねる動きを返す
    mutating func update(state: AvatarState, time: Double) -> Active? {
        if let current = active, time - current.startedAt >= current.kind.duration {
            active = nil
            if isTouchActive {
                isTouchActive = false
                touchReadyAt = time + Self.touchCooldown
            }
        }
        guard state == .idle else {
            // 待機でなくなったら、癖はすぐやめる（触った反応は最後まで）
            if !isTouchActive { active = nil }
            nextIdleAt = nil
            return active
        }
        if active == nil {
            if let at = nextIdleAt {
                if time >= at, let kind = pickIdle() {
                    active = Active(kind: kind, startedAt: time)
                    lastIdleKind = kind
                    scheduleNext(after: time + kind.duration)
                }
            } else {
                scheduleNext(after: time)
            }
        }
        return active
    }

    /// 触られた。反応を始めたら true（待っている間や反応の途中は false）
    @discardableResult
    mutating func touch(time: Double) -> Bool {
        guard !isTouchActive, time >= touchReadyAt else { return false }
        active = Active(kind: set.touch, startedAt: time)
        isTouchActive = true
        return true
    }

    /// 喜ぶ・応援するときに重ねる動き
    func stateOverlay(for state: AvatarState) -> MannerismKind? {
        switch state {
        case .praise: set.praise
        case .encourage: set.encourage
        default: nil
        }
    }

    private mutating func scheduleNext(after time: Double) {
        nextIdleAt = time + Double.random(in: Self.intervalRange, using: &generator)
    }

    private mutating func pickIdle() -> MannerismKind? {
        let candidates = set.idle.count > 1 ? set.idle.filter { $0 != lastIdleKind } : set.idle
        return candidates.randomElement(using: &generator)
    }
}

/// テストで同じ順にするための乱数
struct SplitMixGenerator: RandomNumberGenerator, Sendable {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// 起動引数：確認用に癖をくり返す（`-avatarQuirk glasses`）、触った反応をくり返す（`-avatarAutoTouch`）
enum MannerismDemo {
    static var forcedKind: MannerismKind? {
        MannerismKind(rawValue: UserDefaults.standard.string(forKey: "avatarQuirk") ?? "")
    }
}

// MARK: - 形式ごとの当てはめ

extension AvatarPose: MannerismTarget {
    private static func part(_ part: MannerismPart) -> TeacherPart? {
        switch part {
        case .head: .head
        case .body: .body
        case .armL: .armL
        case .armR: .armR
        case .legL: .legL
        case .legR: .legR
        case .earL, .earR, .tail: nil
        }
    }

    mutating func bend(_ part: MannerismPart, pitch: Float, roll: Float, yaw: Float) {
        guard let part = Self.part(part) else { return }
        let delta = simd_quatf(angle: yaw, axis: [0, 0, 1]) * simd_quatf(angle: roll, axis: [0, 1, 0]) * simd_quatf(angle: pitch, axis: [1, 0, 0])
        joints[part, default: Joint()].rotation = joint(part).rotation * delta
    }

    mutating func raise(_ amount: Float) { lift += amount }
    mutating func squash(_ amount: Float) {}
    mutating func setEyes(_ eyes: MannerismEyes) { self.eyes = eyes == .closed ? .closed : .happy }

    mutating func nudgeAccessory(_ amount: Float) {
        joints[.glasses, default: Joint()].offset.z += amount
    }
}

extension RigPose: MannerismTarget {
    private static func bone(_ part: MannerismPart) -> RigBone {
        switch part {
        case .head: .head
        case .body: .body
        case .armL: .armL
        case .armR: .armR
        case .legL: .legL
        case .legR: .legR
        case .earL: .earL
        case .earR: .earR
        case .tail: .tail
        }
    }

    mutating func bend(_ part: MannerismPart, pitch: Float, roll: Float, yaw: Float) {
        let bone = Self.bone(part)
        let delta = simd_quatf(angle: yaw, axis: [0, 0, 1]) * simd_quatf(angle: roll, axis: [0, 1, 0]) * simd_quatf(angle: pitch, axis: [1, 0, 0])
        rotations[bone] = rotation(bone) * delta
    }

    mutating func raise(_ amount: Float) { lift += amount }
    mutating func squash(_ amount: Float) { squash += amount }

    mutating func setEyes(_ eyes: MannerismEyes) {
        shapes[.eyeBlink] = eyes == .closed ? 1 : 0
        shapes[.eyeHappy] = eyes == .happy ? 1 : 0
    }
}

extension PaperPose: MannerismTarget {
    private static let degrees = 180 / Double.pi

    mutating func bend(_ part: MannerismPart, pitch: Float, roll: Float, yaw: Float) {
        let r = Double(roll) * Self.degrees
        let forward = Double(pitch) * Self.degrees
        switch part {
        case .head: headTilt += r + forward * 0.5 + Double(yaw) * Self.degrees * 0.3
        case .body: bodyTilt += r + forward * 0.3
        case .armL: armL += r + forward * 0.6
        case .armR: armR += r - forward * 0.6
        case .legL, .legR, .earL, .earR, .tail: break
        }
    }

    mutating func raise(_ amount: Float) { lift += Double(amount) * 400 }
    mutating func squash(_ amount: Float) {}
    mutating func setEyes(_ eyes: MannerismEyes) { self.eyes = eyes == .closed ? .closed : .happy }
}
