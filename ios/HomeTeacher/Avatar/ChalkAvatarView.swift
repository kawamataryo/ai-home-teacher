import SwiftUI

/// 黒板に住むチョークの先生「コナ」（#127）。人の体を持たず、目、口、簡単な手だけで気持ちを表す。
///
/// - 開いたときに、描かれるように現れる
/// - 線は 1 秒に 8 回わずかに描き直して、チョークの手描きらしく生きて見せる
/// - 黒板を大きくしたときは黒板の中に住む（背景なし）。先生だけのときは小さな黒板を自分で持つ
struct ChalkAvatarView: View {
    var state: AvatarState
    var lipSync: LipSyncPlayer?
    var mouth: MouthShape?
    /// 黒板の方を向いている角度（度）。正なら黒板を指す
    var turn: Double
    var mannerisms: MannerismSet
    var touches: Int
    /// 黒板の中にいる（背景を描かない）
    var isOnBoard: Bool

    @State private var started = Date()
    @State private var stateChangedAt = Date()
    @State private var motion = PaperMotion()

    /// 描かれるように現れる秒数
    static let drawInDuration = 1.4

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { context in
            let now = context.date
            let elapsed = now.timeIntervalSince(started)
            let (pose, idleMouth) = motion.pose(
                state: state, timeInState: now.timeIntervalSince(stateChangedAt), time: elapsed,
                mannerisms: mannerisms, touches: touches
            )
            let shape = mouth ?? idleMouth ?? lipSync?.update() ?? .closed
            GeometryReader { geometry in
                ZStack {
                    if !isOnBoard {
                        RoundedRectangle(cornerRadius: 26)
                            .fill(Color(red: 0.13, green: 0.25, blue: 0.20))
                            .overlay(RoundedRectangle(cornerRadius: 26).stroke(Color(red: 0.52, green: 0.36, blue: 0.22), lineWidth: 9))
                            .padding(10)
                    }
                    ChalkFace(
                        pose: pose, mouth: shape,
                        pointing: turn > 0,
                        progress: min(elapsed / Self.drawInDuration, 1),
                        boil: Int(elapsed * 8)
                    )
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .onChange(of: state) { stateChangedAt = Date() }
    }
}

/// 線画の顔。座標は 320×400 の枠で考えて、大きさに合わせて縮める
struct ChalkFace: View {
    let pose: PaperPose
    let mouth: MouthShape
    let pointing: Bool
    /// 描かれていく割合（0〜1）
    let progress: Double
    /// 線の描き直しの番号
    let boil: Int

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / 320, size.height / 400) * 0.94
            context.translateBy(x: size.width / 2, y: size.height / 2)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: 0, y: -pose.lift)

            for (index, stroke) in Self.strokes(pose: pose, mouth: mouth, pointing: pointing).enumerated() {
                // 順番に描かれていく
                let start = Double(index) / Double(Self.strokeCount)
                let local = min(max((progress - start) * Double(Self.strokeCount) / 2, 0), 1)
                guard local > 0 else { continue }
                draw(stroke.path.trimmedPath(from: 0, to: local), in: &context, width: stroke.width, color: stroke.color, seed: UInt64(index))
            }
        }
    }

    /// チョークらしく、少しずらした線を重ねる
    private func draw(_ path: Path, in context: inout GraphicsContext, width: CGFloat, color: Color, seed: UInt64) {
        var random = SplitMixGenerator(state: seed &* 31 &+ UInt64(boil))
        // 粉のにじみ
        context.stroke(path, with: .color(color.opacity(0.22)), style: StrokeStyle(lineWidth: width * 2.2, lineCap: .round, lineJoin: .round))
        for layer in 0..<3 {
            let dx = CGFloat.random(in: -1.3...1.3, using: &random)
            let dy = CGFloat.random(in: -1.3...1.3, using: &random)
            let shifted = path.applying(CGAffineTransform(translationX: dx, y: dy))
            let dash: [CGFloat] = layer == 2 ? [CGFloat.random(in: 9...16, using: &random), CGFloat.random(in: 1...3, using: &random)] : []
            context.stroke(shifted, with: .color(color.opacity(layer == 0 ? 0.95 : 0.55)), style: StrokeStyle(lineWidth: width * (layer == 0 ? 0.8 : 0.55), lineCap: .round, lineJoin: .round, dash: dash))
        }
    }

    struct Stroke {
        var path: Path
        var width: CGFloat = 8
        var color = Color(red: 0.97, green: 0.97, blue: 0.93)
    }

    /// 線の数（描かれていく順番を決める）
    static let strokeCount = 8
    private static let chalkYellow = Color(red: 0.99, green: 0.88, blue: 0.45)
    private static let chalkPink = Color(red: 0.98, green: 0.62, blue: 0.68)

    static func strokes(pose: PaperPose, mouth: MouthShape, pointing: Bool) -> [Stroke] {
        let tilt = CGAffineTransform(rotationAngle: pose.headTilt * .pi / 180)
            .concatenating(CGAffineTransform(translationX: 0, y: -62))
        var result: [Stroke] = []
        // 目：大きなだ円と光の点。線画でも小さく読めるように大きめ
        for x: CGFloat in [-62, 62] {
            result.append(Stroke(path: eye(pose.eyes).applying(CGAffineTransform(translationX: x, y: -8)).applying(tilt), width: 10))
        }
        // 口
        result.append(Stroke(path: mouthPath(mouth).applying(CGAffineTransform(translationX: 0, y: 62)).applying(tilt), width: 9))
        // ほっぺ（ピンクのチョーク）
        for x: CGFloat in [-106, 106] {
            var cheek = Path()
            cheek.move(to: CGPoint(x: x - 14, y: 42))
            cheek.addLine(to: CGPoint(x: x - 4, y: 30))
            cheek.move(to: CGPoint(x: x + 2, y: 42))
            cheek.addLine(to: CGPoint(x: x + 12, y: 30))
            result.append(Stroke(path: cheek.applying(tilt), width: 5, color: chalkPink))
        }
        // 手：キャラの右手（画面の左）と左手。肩のかわりの点のまわりで回す
        result.append(hand(side: -1, angle: pointing ? 118 : pose.armR, isPointing: pointing))
        result.append(hand(side: 1, angle: pose.armL, isPointing: false))
        // 手に持った短いチョーク（チャームポイント）
        result.append(chalkStub(angle: pose.armL))
        return result
    }

    private static func eye(_ shape: EyeShape) -> Path {
        var path = Path()
        switch shape {
        case .open:
            path.addEllipse(in: CGRect(x: -22, y: -32, width: 44, height: 62))
            // 光の点
            path.addEllipse(in: CGRect(x: 2, y: -18, width: 8, height: 10))
        case .closed:
            path.move(to: CGPoint(x: -26, y: 0))
            path.addQuadCurve(to: CGPoint(x: 26, y: 0), control: CGPoint(x: 0, y: 18))
        case .happy:
            path.move(to: CGPoint(x: -28, y: 10))
            path.addQuadCurve(to: CGPoint(x: 28, y: 10), control: CGPoint(x: 0, y: -30))
        }
        return path
    }

    private static func mouthPath(_ shape: MouthShape) -> Path {
        var path = Path()
        func oval(_ w: CGFloat, _ h: CGFloat) { path.addEllipse(in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h)) }
        switch shape {
        case .a: oval(58, 54)
        case .i: oval(70, 18)
        case .u: oval(26, 24)
        case .e: oval(58, 30)
        case .o: oval(40, 46)
        case .n:
            path.move(to: CGPoint(x: -20, y: 0))
            path.addLine(to: CGPoint(x: 20, y: 0))
        case .closed:
            path.move(to: CGPoint(x: -34, y: -4))
            path.addQuadCurve(to: CGPoint(x: 34, y: -4), control: CGPoint(x: 0, y: 22))
        }
        return path
    }

    private static func hand(side: CGFloat, angle: Double, isPointing: Bool) -> Stroke {
        var path = Path()
        // 手のひら（丸）と指。指さしなら 1 本だけ長く
        path.addEllipse(in: CGRect(x: -16, y: 18, width: 32, height: 30))
        if isPointing {
            path.move(to: CGPoint(x: 0, y: 48))
            path.addLine(to: CGPoint(x: 0, y: 84))
        } else {
            for dx: CGFloat in [-10, 0, 10] {
                path.move(to: CGPoint(x: dx, y: 46))
                path.addLine(to: CGPoint(x: dx * 1.3, y: 62))
            }
        }
        // 上から下へぶら下がる形を、肩の点のまわりで回す（paper と同じ向き：外へ開くと上がる）
        let transform = CGAffineTransform(rotationAngle: angle * .pi / 180)
            .concatenating(CGAffineTransform(translationX: side * 84, y: 68))
        return Stroke(path: path.applying(transform), width: 7)
    }

    private static func chalkStub(angle: Double) -> Stroke {
        var path = Path()
        path.addRoundedRect(in: CGRect(x: 14, y: 32, width: 26, height: 12), cornerSize: CGSize(width: 3, height: 3))
        let transform = CGAffineTransform(rotationAngle: angle * .pi / 180)
            .concatenating(CGAffineTransform(translationX: 84, y: 68))
        return Stroke(path: path.applying(transform), width: 6, color: chalkYellow)
    }
}
