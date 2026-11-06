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
            let hop = abs(sin(t * .pi * 1.6))
            pose.lift = 26 * hop
            pose.armL = -150 + 15 * sin(t * 9)
            pose.armR = 150 - 15 * sin(t * 9)
            pose.headTilt = 6 * sin(t * 5)
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

/// 2D のキャラの表示（試作）。SwiftUI のパーツの回転と差し替えで動かす（#121）。本番の絵は #126 / #127
struct PaperAvatarView: View {
    var state: AvatarState
    var lipSync: LipSyncPlayer?
    var mouth: MouthShape?
    var turn: Double

    @State private var started = Date()
    @State private var stateChangedAt = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let now = context.date
            let pose = PaperPose.make(
                state: state, timeInState: now.timeIntervalSince(stateChangedAt), time: now.timeIntervalSince(started)
            )
            let shape = mouth ?? lipSync?.update() ?? .closed
            GeometryReader { geometry in
                let scale = min(geometry.size.width / 320, geometry.size.height / 400)
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

/// 試作の紙人形
private struct PaperDoll: View {
    let pose: PaperPose
    let mouth: MouthShape

    private let paper = Color(red: 0.98, green: 0.82, blue: 0.68)
    private let cloth = Color(red: 0.30, green: 0.55, blue: 0.75)

    var body: some View {
        ZStack {
            arm(angle: pose.armL, x: 112)
            arm(angle: pose.armR, x: 208)
            RoundedRectangle(cornerRadius: 24)
                .fill(cloth)
                .frame(width: 110, height: 140)
                .position(x: 160, y: 270)
                .shadow(color: .black.opacity(0.25), radius: 1, x: 2, y: 3)
            ZStack {
                Circle().fill(paper).frame(width: 150, height: 150)
                    .shadow(color: .black.opacity(0.25), radius: 1, x: 2, y: 3)
                eye(x: -32)
                eye(x: 32)
                PaperMouth(shape: mouth).offset(y: 34)
            }
            .rotationEffect(.degrees(pose.headTilt), anchor: UnitPoint(x: 0.5, y: 0.9))
            .position(x: 160, y: 130)
        }
        .rotationEffect(.degrees(pose.bodyTilt), anchor: .bottom)
        .offset(y: -pose.lift)
    }

    private func arm(angle: Double, x: CGFloat) -> some View {
        Capsule().fill(cloth)
            .frame(width: 34, height: 96)
            .shadow(color: .black.opacity(0.25), radius: 1, x: 2, y: 3)
            .rotationEffect(.degrees(angle), anchor: .top)
            .position(x: x, y: 262)
    }

    @ViewBuilder
    private func eye(x: CGFloat) -> some View {
        switch pose.eyes {
        case .open:
            Ellipse().fill(.black).frame(width: 18, height: 24).offset(x: x, y: -8)
        case .closed:
            Capsule().fill(.black).frame(width: 22, height: 5).offset(x: x, y: -6)
        case .happy:
            Text("︶").font(.system(size: 26, weight: .black)).rotationEffect(.degrees(180)).offset(x: x, y: -8)
        }
    }
}

/// 口の形
struct PaperMouth: View {
    let shape: MouthShape

    private var size: CGSize {
        switch shape {
        case .a: CGSize(width: 34, height: 30)
        case .i: CGSize(width: 40, height: 10)
        case .u: CGSize(width: 16, height: 14)
        case .e: CGSize(width: 34, height: 18)
        case .o: CGSize(width: 24, height: 26)
        case .n: CGSize(width: 24, height: 5)
        case .closed: CGSize(width: 28, height: 4)
        }
    }

    var body: some View {
        Capsule().fill(Color(red: 0.55, green: 0.12, blue: 0.15)).frame(width: size.width, height: size.height)
    }
}
