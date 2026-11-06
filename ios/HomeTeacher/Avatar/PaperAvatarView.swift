import SwiftUI

/// 切り絵の人形の、ある瞬間の姿勢（度とポイント。大きさの基準は高さ 400）
struct PaperPose: Equatable, Sendable {
    var bodyTilt: Double = 0
    var headTilt: Double = 0
    var armL: Double = 0
    var armR: Double = 0
    var lift: Double = 0
    var eyes: EyeShape = .open

    /// 紙人形らしく、動きは 1 秒に 10 コマに区切る（少しぎこちなく見せる）
    static let framesPerSecond = 10.0

    static func make(state: AvatarState, timeInState rawT: Double, time rawG: Double) -> PaperPose {
        let t = (rawT * framesPerSecond).rounded(.down) / framesPerSecond
        let g = (rawG * framesPerSecond).rounded(.down) / framesPerSecond
        var pose = PaperPose()
        pose.bodyTilt = 1.5 * sin(g * 1.2)
        pose.headTilt = -2 * sin(g * 1.2 + 0.6)
        pose.armL = -8
        pose.armR = 8
        pose.eyes = AvatarPose.isBlinking(at: rawG) ? .closed : .open
        switch state {
        case .idle:
            break
        case .listening:
            pose.headTilt = 6 + 6 * (0.5 - 0.5 * cos(t * 2 * .pi / 1.2))
        case .thinking:
            pose.headTilt = -14
            pose.armR = 130
            pose.bodyTilt = 3
        case .looking:
            pose.headTilt = 16
            pose.bodyTilt = 6
            pose.armL = -30
            pose.armR = 30
        case .talking:
            pose.headTilt = 3 * sin(g * 4)
            pose.armL = -14 - 12 * sin(g * 3)
            pose.armR = 14 + 10 * sin(g * 2.4 + 1)
        case .praise:
            // うれしいときの動きを大きくする：大きく跳ねて、紙がしなるように傾く
            let hop = abs(sin(t * .pi * 1.6))
            pose.lift = 42 * hop
            pose.bodyTilt = 9 * sin(t * .pi * 1.6)
            pose.armL = -155 + 22 * sin(t * 9)
            pose.armR = 155 - 22 * sin(t * 9)
            pose.headTilt = 10 * sin(t * 5)
            pose.eyes = .happy
        case .encourage:
            let pump = sin(t * 7)
            pose.armR = 150 + 15 * pump
            pose.armL = -40
            pose.lift = 5 + 5 * pump
        case .break:
            let stretch = 0.5 - 0.5 * cos(t * 2 * .pi / 6)
            pose.armL = -8 - 160 * stretch
            pose.armR = 8 + 160 * stretch
            pose.headTilt = -6 * stretch
            pose.lift = 6 * stretch
            if stretch > 0.7 { pose.eyes = .closed }
        }
        return pose
    }
}

/// 切り絵の 2D のキャラの表示（#121, #126）。SwiftUI のパーツの回転と差し替えで動かす
struct PaperAvatarView: View {
    var state: AvatarState
    var lipSync: LipSyncPlayer?
    var mouth: MouthShape?
    var turn: Double
    var mannerisms: MannerismSet = MannerismSet()
    var touches: Int = 0

    @State private var started = Date()
    @State private var stateChangedAt = Date()
    @State private var motion = PaperMotion()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let now = context.date
            let (pose, idleMouth) = motion.pose(
                state: state, timeInState: now.timeIntervalSince(stateChangedAt), time: now.timeIntervalSince(started),
                mannerisms: mannerisms, touches: touches
            )
            let shape = mouth ?? idleMouth ?? lipSync?.update() ?? .closed
            GeometryReader { geometry in
                let scale = min(geometry.size.width / 320, geometry.size.height / 400) * 0.9
                PaperDoll(pose: pose, mouth: shape)
                    .frame(width: 320, height: 400)
                    .scaleEffect(scale)
                    .rotation3DEffect(.degrees(-turn), axis: (x: 0, y: 1, z: 0), perspective: 0.3)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
        }
        .onChange(of: state) { stateChangedAt = Date() }
    }
}

/// 姿勢に癖を重ねる（`TimelineView` の中から呼ぶ）
@MainActor
final class PaperMotion {
    private var scheduler: MannerismScheduler?
    private var seenTouches = 0

    func pose(
        state: AvatarState, timeInState: Double, time: Double, mannerisms: MannerismSet, touches: Int
    ) -> (PaperPose, MouthShape?) {
        var scheduler = scheduler ?? MannerismScheduler(set: mannerisms)
        var pose = PaperPose.make(state: state, timeInState: timeInState, time: time)
        if touches != seenTouches {
            seenTouches = touches
            scheduler.touch(time: time)
        }
        if let overlay = scheduler.stateOverlay(for: state) {
            overlay.apply(elapsed: timeInState.truncatingRemainder(dividingBy: overlay.duration), to: &pose)
        }
        var mouth: MouthShape?
        if let forced = MannerismDemo.forcedKind {
            mouth = forced.apply(elapsed: time.truncatingRemainder(dividingBy: forced.duration + 1), to: &pose)
        } else if let active = scheduler.update(state: state, time: time) {
            mouth = active.kind.apply(elapsed: time - active.startedAt, to: &pose)
        }
        self.scheduler = scheduler
        return (pose, mouth)
    }
}

/// 切り絵の勉強仲間「ソラ」。色紙を切って割りピンで留めた人形（#126）。
/// ふちは手で切ったように少しがたがたさせ、パーツごとに紙の影を落とす。
private struct PaperDoll: View {
    let pose: PaperPose
    let mouth: MouthShape

    private static let skin = Color(red: 0.98, green: 0.80, blue: 0.64)
    private static let hair = Color(red: 0.16, green: 0.20, blue: 0.36)
    private static let hoodie = Color(red: 0.98, green: 0.74, blue: 0.20)
    private static let hoodieDark = Color(red: 0.93, green: 0.60, blue: 0.14)
    private static let pants = Color(red: 0.25, green: 0.56, blue: 0.62)
    private static let shoe = Color(red: 0.90, green: 0.33, blue: 0.30)
    private static let cheek = Color(red: 0.98, green: 0.58, blue: 0.56)

    var body: some View {
        ZStack {
            // 足（立っているだけ。少しだけ前後にずらす）
            cut(CutRect(seed: 11), color: Self.pants, x: 132, y: 335, w: 36, h: 62)
            cut(CutRect(seed: 12), color: Self.pants, x: 188, y: 335, w: 36, h: 62)
            cut(CutRect(seed: 13, corner: 12), color: Self.shoe, x: 126, y: 372, w: 52, h: 24)
            cut(CutRect(seed: 14, corner: 12), color: Self.shoe, x: 194, y: 372, w: 52, h: 24)
            // キャラの右腕（画面の左）はうしろ
            arm(angle: pose.armR, x: 108, seed: 21)
            // 体（パーカー）
            cut(CutRect(seed: 31, corner: 22), color: Self.hoodie, x: 160, y: 262, w: 118, h: 128)
            cut(CutRect(seed: 32, corner: 8), color: Self.hoodieDark, x: 160, y: 298, w: 68, h: 30)
            // キャラの左腕（画面の右）は前。腕は画面の外へ開く向きが、ふだんの向き
            arm(angle: pose.armL, x: 212, seed: 22)
            ZStack {
                head
            }
            .rotationEffect(.degrees(pose.headTilt), anchor: UnitPoint(x: 0.5, y: 0.5 + 95 / 400))
            pin(x: 160, y: 205)
        }
        .frame(width: 320, height: 400)
        .rotationEffect(.degrees(pose.bodyTilt), anchor: .bottom)
        .offset(y: -pose.lift)
    }

    private var head: some View {
        ZStack {
            // うしろ髪
            cut(CutBlob(seed: 41), color: Self.hair, x: 160, y: 118, w: 192, h: 178)
            // 顔
            cut(CutBlob(seed: 42, wobble: 1.5), color: Self.skin, x: 160, y: 130, w: 158, h: 146)
            // 前髪（ぎざぎざのはさみのあと。チャームポイント）
            cut(CutBangs(), color: Self.hair, x: 160, y: 84, w: 176, h: 72)
            // 頭の上のはねた紙
            cut(CutRect(seed: 44, corner: 3), color: Self.hair, x: 188, y: 34, w: 18, h: 44).rotationEffect(.degrees(18), anchor: UnitPoint(x: 188 / 320, y: 40 / 400))
            // ほっぺ
            Circle().fill(Self.cheek.opacity(0.8)).frame(width: 30, height: 30).position(x: 104, y: 150)
            Circle().fill(Self.cheek.opacity(0.8)).frame(width: 30, height: 30).position(x: 216, y: 150)
            eye(x: 124)
            eye(x: 196)
            PaperMouth(shape: mouth).position(x: 160, y: 168)
        }
    }

    /// 紙を切ったパーツ：影を落とす
    private func cut<S: Shape>(_ shape: S, color: Color, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) -> some View {
        shape.fill(color)
            .overlay(shape.stroke(.white.opacity(0.18), lineWidth: 1))
            .frame(width: w, height: h)
            .shadow(color: .black.opacity(0.28), radius: 0.8, x: 1.5, y: 2.5)
            .position(x: x, y: y)
    }

    /// 腕：肩の割りピンで回る
    private func arm(angle: Double, x: CGFloat, seed: UInt64) -> some View {
        ZStack {
            cut(CutRect(seed: seed, corner: 14), color: Self.hoodieDark, x: 26, y: 56, w: 40, h: 94)
            cut(CutBlob(seed: seed + 10, wobble: 1.2), color: Self.skin, x: 26, y: 112, w: 34, h: 32)
            pin(x: 26, y: 20)
        }
        .frame(width: 52, height: 132)
        // 画面の右の腕は負で、左の腕は正で外へ開いて上がる
        .rotationEffect(.degrees(angle), anchor: UnitPoint(x: 0.5, y: 20 / 132))
        .position(x: x, y: 278)
    }

    /// 割りピン（紙人形の関節）
    private func pin(x: CGFloat, y: CGFloat) -> some View {
        Circle()
            .fill(RadialGradient(colors: [Color(red: 0.98, green: 0.88, blue: 0.55), Color(red: 0.72, green: 0.54, blue: 0.20)], center: .topLeading, startRadius: 0, endRadius: 8))
            .frame(width: 10, height: 10)
            .shadow(color: .black.opacity(0.35), radius: 0.5, x: 0.5, y: 1)
            .position(x: x, y: y)
    }

    @ViewBuilder
    private func eye(x: CGFloat) -> some View {
        switch pose.eyes {
        case .open:
            ZStack {
                Ellipse().fill(Color(red: 0.08, green: 0.08, blue: 0.14)).frame(width: 30, height: 40)
                Circle().fill(.white).frame(width: 11, height: 11).offset(x: 5, y: -8)
            }
            .position(x: x, y: 124)
        case .closed:
            ArcLine(up: false).stroke(Color(red: 0.08, green: 0.08, blue: 0.14), style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .frame(width: 34, height: 12).position(x: x, y: 128)
        case .happy:
            ArcLine(up: true).stroke(Color(red: 0.08, green: 0.08, blue: 0.14), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .frame(width: 36, height: 16).position(x: x, y: 124)
        }
    }
}

/// 弧の線
private struct ArcLine: Shape {
    var up: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: up ? rect.maxY : rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: up ? rect.maxY : rect.minY),
            control: CGPoint(x: rect.midX, y: up ? rect.minY - rect.height : rect.maxY + rect.height)
        )
        return path
    }
}

/// 手で切ったような、少しがたがたの四角
struct CutRect: Shape {
    var seed: UInt64
    var corner: CGFloat = 6

    func path(in rect: CGRect) -> Path {
        var random = SplitMixGenerator(state: seed)
        var points: [CGPoint] = []
        let c = min(corner, min(rect.width, rect.height) / 2)
        let raw = [
            CGPoint(x: rect.minX + c, y: rect.minY), CGPoint(x: rect.maxX - c, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY + c), CGPoint(x: rect.maxX, y: rect.maxY - c),
            CGPoint(x: rect.maxX - c, y: rect.maxY), CGPoint(x: rect.minX + c, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY - c), CGPoint(x: rect.minX, y: rect.minY + c),
        ]
        for p in raw {
            points.append(CGPoint(x: p.x + .random(in: -1.5...1.5, using: &random), y: p.y + .random(in: -1.5...1.5, using: &random)))
        }
        var path = Path()
        path.addLines(points)
        path.closeSubpath()
        return path
    }
}

/// 手で切ったような丸
struct CutBlob: Shape {
    var seed: UInt64
    var wobble: CGFloat = 2.5
    var sides = 18

    func path(in rect: CGRect) -> Path {
        var random = SplitMixGenerator(state: seed)
        var path = Path()
        for i in 0..<sides {
            let a = Double(i) / Double(sides) * 2 * .pi
            let r = CGFloat.random(in: -wobble...wobble, using: &random)
            let p = CGPoint(x: rect.midX + (rect.width / 2 + r) * CGFloat(cos(a)), y: rect.midY + (rect.height / 2 + r) * CGFloat(sin(a)))
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        return path
    }
}

/// はさみで切ったぎざぎざの前髪
struct CutBangs: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + h * 0.62))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + h * 0.62), control: CGPoint(x: rect.midX, y: rect.minY - h * 0.5))
        let zig: [(CGFloat, CGFloat)] = [(0.94, 0.95), (0.84, 0.6), (0.72, 0.98), (0.6, 0.62), (0.47, 1.0), (0.36, 0.64), (0.24, 0.95), (0.13, 0.6), (0.05, 0.92)]
        for (x, y) in zig { path.addLine(to: CGPoint(x: rect.minX + w * x, y: rect.minY + h * y)) }
        path.closeSubpath()
        return path
    }
}

/// 口の形
struct PaperMouth: View {
    let shape: MouthShape

    private var size: CGSize {
        switch shape {
        case .a: CGSize(width: 38, height: 34)
        case .i: CGSize(width: 44, height: 12)
        case .u: CGSize(width: 18, height: 16)
        case .e: CGSize(width: 38, height: 20)
        case .o: CGSize(width: 26, height: 30)
        case .n: CGSize(width: 26, height: 6)
        case .closed: CGSize(width: 30, height: 5)
        }
    }

    var body: some View {
        Capsule().fill(Color(red: 0.55, green: 0.12, blue: 0.15)).frame(width: size.width, height: size.height)
    }
}
