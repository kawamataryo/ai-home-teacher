import SwiftUI

/// 黒板そのもの（板・チョークのあと・木の枠・チョーク置き）。中身は `content` に入れる（#105）。
///
/// 枠と受け皿は実際の大きさ（pt）で描き、中身だけを呼び出し側で縮める。黒板が小さな看板になっても枠が細くなりすぎない
struct BoardSurface<Content: View>: View {
    var frameWidth: CGFloat = 14
    /// チョーク置きを出すか（小さな看板では出さない）
    var showsTray = true
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(frameWidth)
            .background {
                ZStack {
                    LinearGradient(colors: [Chalk.board, Chalk.boardDeep], startPoint: .top, endPoint: .bottom)
                    ChalkSmudges()
                }
                .padding(frameWidth * 0.5)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(BoardFrame(width: frameWidth))
            .overlay(alignment: .bottom) {
                if showsTray {
                    ChalkTray()
                        .padding(.horizontal, frameWidth * 3)
                        .offset(y: 6)
                }
            }
            .foregroundStyle(Chalk.white)
    }
}

/// 木の枠。上が明るく下が暗い（光が上から当たる）
private struct BoardFrame: View {
    let width: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(
                LinearGradient(colors: [Chalk.frame.opacity(0.95), Chalk.frame, Chalk.frameDeep], startPoint: .top, endPoint: .bottom),
                lineWidth: width
            )
            .overlay(
                // 板との境目の影
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.black.opacity(0.25), lineWidth: 2)
                    .padding(width - 1)
            )
            .shadow(color: .black.opacity(0.18), radius: 6, y: 3)
    }
}

/// 消したあとのチョークの跡。毎回同じ形にする（乱数は固定の種から）
private struct ChalkSmudges: View {
    var body: some View {
        Canvas { context, size in
            var rng = SeededRandom(seed: 105)
            for _ in 0..<14 {
                let x = rng.next() * size.width
                let y = rng.next() * size.height
                let w = size.width * (0.12 + rng.next() * 0.25)
                let h = size.height * (0.03 + rng.next() * 0.06)
                let rect = CGRect(x: x - w / 2, y: y - h / 2, width: w, height: h)
                context.opacity = 0.025 + rng.next() * 0.035
                context.fill(Path(ellipseIn: rect), with: .color(.white))
            }
            // 黒板消しで横に拭いた跡
            for i in 0..<3 {
                let y = size.height * (0.25 + Double(i) * 0.24 + rng.next() * 0.05)
                var path = Path()
                path.move(to: CGPoint(x: size.width * 0.06, y: y))
                path.addQuadCurve(
                    to: CGPoint(x: size.width * 0.94, y: y + size.height * 0.02),
                    control: CGPoint(x: size.width * 0.5, y: y - size.height * 0.04)
                )
                context.opacity = 0.03
                context.stroke(path, with: .color(.white), style: StrokeStyle(lineWidth: size.height * 0.08, lineCap: .round))
            }
        }
        .blur(radius: 6)
        .allowsHitTesting(false)
    }
}

/// チョーク置き（白・黄・桃・水色のチョークと黒板消し）
private struct ChalkTray: View {
    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            chalk(Chalk.white, length: 44)
            chalk(Chalk.yellow, length: 32)
            chalk(Chalk.pink, length: 38)
            chalk(Chalk.blue, length: 26)
            Spacer(minLength: 0)
            BoardEraser()
                .frame(width: 70, height: 22)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 9)
        .frame(height: 30, alignment: .bottom)
        .background(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 4)
                .fill(LinearGradient(colors: [Chalk.frame, Chalk.frameDeep], startPoint: .top, endPoint: .bottom))
                .frame(height: 12)
                .shadow(color: .black.opacity(0.25), radius: 3, y: 2)
        }
        .frame(maxWidth: 560)
    }

    private func chalk(_ color: Color, length: CGFloat) -> some View {
        Capsule()
            .fill(color)
            .frame(width: length, height: 8)
            .overlay(Capsule().fill(.white.opacity(0.3)).frame(height: 2).offset(y: -1.5))
    }
}

/// 黒板消し（受け皿の上と、図を消すときに使う）
struct BoardEraser: View {
    var body: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(red: 0.36, green: 0.42, blue: 0.70))
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(white: 0.88))
                .frame(height: 6)
        }
        .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
    }
}

// MARK: - 図の差し替え

/// 図が替わるとき、前の図を黒板消しで左から右へ拭き取る。次の図は拭き終わってから書く
struct BoardEraseTransition: Transition {
    static let duration: Double = 0.55

    func body(content: Content, phase: TransitionPhase) -> some View {
        let erased = phase == .didDisappear
        content
            .mask {
                GeometryReader { geometry in
                    let w = geometry.size.width
                    LinearGradient(
                        stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.12)],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: w * 1.3)
                    .offset(x: erased ? w : -w * 0.3)
                }
            }
            .overlay(alignment: .leading) {
                GeometryReader { geometry in
                    let w = geometry.size.width
                    BoardEraser()
                        .frame(width: 70, height: geometry.size.height * 0.9)
                        .rotationEffect(.degrees(erased ? 4 : -4))
                        .offset(x: erased ? w + 20 : -110, y: geometry.size.height * 0.05)
                }
            }
    }
}

extension AnyTransition {
    /// 図の入れ替え（前の図を拭き取ってから、次の図を出す）
    @MainActor static var boardRewrite: AnyTransition {
        .asymmetric(
            insertion: AnyTransition(.opacity.animation(.easeOut(duration: 0.3).delay(BoardEraseTransition.duration * 0.8))),
            removal: AnyTransition(BoardEraseTransition().animation(.easeInOut(duration: BoardEraseTransition.duration)))
        )
    }
}

// MARK: - チョークで書く

/// 文字を左から右へ書いていくように見せる（タイトルなど）
struct ChalkWriteIn: ViewModifier {
    @Environment(\.boardAnimated) private var animated
    let characters: Int
    @State private var progress: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .mask(alignment: .leading) {
                GeometryReader { geometry in
                    Rectangle().frame(width: geometry.size.width * (animated ? progress : 1))
                }
            }
            .task {
                guard animated, progress == 0 else { return }
                // 1文字 0.035 秒くらい（最短 0.35 秒・最長 1.2 秒）
                let seconds = min(1.2, max(0.35, Double(characters) * 0.035))
                withAnimation(.linear(duration: seconds)) { progress = 1 }
            }
    }
}

extension View {
    func chalkWriteIn(characters: Int) -> some View {
        modifier(ChalkWriteIn(characters: characters))
    }
}

/// 固定の種から作る乱数（黒板の跡を毎回同じにする）
private struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 }

    /// 0..<1
    mutating func next() -> Double {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Double(state % 10_000) / 10_000
    }
}
