import SwiftUI

/// 自由に描く黒板（#107）。図形を 1 つずつチョークで書くように出す（線は始点から伸ばし、文字はふわっと出す）。
/// 段階表示（`boardRevealCount`）のときは、`step` の番号の順に見せる。
struct ChalkDrawingView: View {
    let model: ChalkDrawing
    @Environment(\.boardRevealCount) private var revealCount

    var body: some View {
        GeometryReader { geometry in
            let frame = Self.frame(in: geometry.size)
            ZStack(alignment: .topLeading) {
                ForEach(Array(model.shapes.enumerated()), id: \.offset) { index, shape in
                    let unit = model.revealIndex(of: shape)
                    if unit < revealCount, shape.parsedKind != nil {
                        ChalkShapeView(shape: shape, frame: frame, delay: Self.delay(index: index, unit: unit, in: model))
                            .transition(.opacity)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .frame(minHeight: 360)
        .animation(.easeInOut(duration: 0.3), value: revealCount)
    }

    /// 描く場所（よこ 100 × たて 70 を、比を変えずに真ん中に置く）
    struct Frame: Equatable {
        var scale: CGFloat
        var origin: CGPoint

        func point(_ p: CGPoint) -> CGPoint {
            CGPoint(x: origin.x + p.x * scale, y: origin.y + p.y * scale)
        }

        var transform: CGAffineTransform {
            CGAffineTransform(translationX: origin.x, y: origin.y).scaledBy(x: scale, y: scale)
        }
    }

    static func frame(in size: CGSize) -> Frame {
        let scale = min(size.width / ChalkDrawing.width, size.height / ChalkDrawing.height)
        return Frame(
            scale: scale,
            origin: CGPoint(x: (size.width - ChalkDrawing.width * scale) / 2, y: (size.height - ChalkDrawing.height * scale) / 2)
        )
    }

    /// 同じ段階の中では、並んだ順に少しずつ遅らせて書く
    static func delay(index: Int, unit: Int, in model: ChalkDrawing) -> Double {
        let order = model.shapes[..<index].filter { model.revealIndex(of: $0) == unit }.count
        return Double(order) * 0.16
    }
}

/// 図形 1 つ。線はチョークで引くように伸ばす
private struct ChalkShapeView: View {
    let shape: ChalkDrawing.Shape
    let frame: ChalkDrawingView.Frame
    let delay: Double
    @Environment(\.boardAnimated) private var animated
    @State private var progress: CGFloat = 0

    private var drawn: CGFloat { animated ? progress : 1 }

    var body: some View {
        let geometry = ChalkGeometry(shape: shape)
        let color = Chalk.color(named: shape.color)
        let lineWidth = max(frame.scale * 0.45, 2)
        ZStack(alignment: .topLeading) {
            if shape.fill, let fill = geometry.fill {
                fill.applying(frame.transform)
                    .fill(color.opacity(0.22))
                    .opacity(Double(drawn))
            }
            if let accent = geometry.accent {
                accent.applying(frame.transform)
                    .fill(Chalk.pink.opacity(0.75))
                    .opacity(Double(drawn))
            }
            if shape.fill, let liquid = geometry.liquid {
                liquid.applying(frame.transform)
                    .fill(Chalk.blue.opacity(0.35))
                    .opacity(Double(drawn))
            }
            geometry.stroke.applying(frame.transform)
                .trim(from: 0, to: drawn)
                .stroke(color, style: StrokeStyle(
                    lineWidth: lineWidth, lineCap: .round, lineJoin: .round,
                    dash: shape.dashed ? [lineWidth * 2.4, lineWidth * 2] : []
                ))
                .shadow(color: color.opacity(0.35), radius: 1.5)
            ForEach(Array(geometry.labels.enumerated()), id: \.offset) { _, label in
                Text(label.text)
                    .font(Chalk.font(frame.scale * label.size, weight: .bold))
                    .foregroundStyle(label.usesShapeColor ? color : Chalk.white)
                    .fixedSize()
                    .position(frame.point(label.at))
                    .opacity(Double(drawn))
            }
        }
        .allowsHitTesting(false)
        .task {
            guard animated, progress == 0 else { return }
            try? await Task.sleep(for: .seconds(delay))
            withAnimation(.easeOut(duration: geometry.drawDuration)) { progress = 1 }
        }
    }
}

extension Chalk {
    /// 図形の色の名前（white・yellow・pink・blue）。知らない名前は白
    static func color(named name: String) -> Color {
        switch name.lowercased() {
        case "yellow": yellow
        case "pink", "red": pink
        case "blue": blue
        default: white
        }
    }
}

// MARK: - 図形の形

/// 図形の線・ぬる所・文字（座標は黒板の よこ100 × たて70）
struct ChalkGeometry {
    struct Label {
        var text: String
        var at: CGPoint
        /// 文字の大きさ（黒板の座標で）
        var size: CGFloat
        var usesShapeColor: Bool
    }

    var stroke = Path()
    var fill: Path?
    /// スタンプの色を付ける所（炎・磁石の N 極・温度計の液）
    var accent: Path?
    /// 入れ物の液体（fill のとき）
    var liquid: Path?
    var labels: [Label] = []
    var drawDuration: Double = 0.45

    init(shape: ChalkDrawing.Shape) {
        let points = shape.cgPoints
        let labelSize: CGFloat = 3.0 * CGFloat(shape.scale)
        switch shape.parsedKind {
        case .line?, .arrow?, .doubleArrow?:
            guard points.count >= 2 else { return }
            let a = points[0], b = points[points.count - 1]
            stroke.move(to: a)
            for p in points.dropFirst() { stroke.addLine(to: p) }
            if shape.parsedKind == .arrow || shape.parsedKind == .doubleArrow {
                Self.addHead(to: &stroke, tip: b, from: points[points.count - 2])
            }
            if shape.parsedKind == .doubleArrow { Self.addHead(to: &stroke, tip: a, from: points[1]) }
            if !shape.text.isEmpty {
                labels.append(Label(text: shape.text, at: Self.labelPoint(a, b), size: labelSize, usesShapeColor: true))
            }
        case .rect?:
            guard points.count >= 2 else { return }
            let rect = CGRect(x: min(points[0].x, points[1].x), y: min(points[0].y, points[1].y),
                              width: abs(points[1].x - points[0].x), height: abs(points[1].y - points[0].y))
            stroke.addRect(rect)
            fill = Path(rect)
            if !shape.text.isEmpty {
                labels.append(Label(text: shape.text, at: CGPoint(x: rect.midX, y: rect.midY), size: labelSize, usesShapeColor: false))
            }
        case .circle?:
            guard let c = points.first else { return }
            let r = CGFloat(shape.radius > 0 ? min(shape.radius, 40) : 6)
            let rect = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
            stroke.addEllipse(in: rect)
            fill = Path(ellipseIn: rect)
            if !shape.text.isEmpty {
                labels.append(Label(text: shape.text, at: c, size: labelSize, usesShapeColor: false))
            }
        case .polygon?, .polyline?:
            guard points.count >= 2 else { return }
            stroke.addLines(points)
            if shape.parsedKind == .polygon { stroke.closeSubpath() }
            fill = shape.parsedKind == .polygon ? stroke : nil
            if !shape.text.isEmpty {
                labels.append(Label(text: shape.text, at: Self.centroid(points), size: labelSize, usesShapeColor: false))
            }
        case .curve?:
            guard points.count >= 2 else { return }
            stroke = Self.smoothCurve(through: points)
            drawDuration = 0.7
            if !shape.text.isEmpty {
                let mid = points[points.count / 2]
                labels.append(Label(text: shape.text, at: CGPoint(x: mid.x, y: mid.y - 3.5), size: labelSize, usesShapeColor: true))
            }
        case .angle?:
            guard points.count >= 3 else { return }
            let v = points[0]
            let a1 = atan2(points[1].y - v.y, points[1].x - v.x)
            let a2 = atan2(points[2].y - v.y, points[2].x - v.x)
            var delta = a2 - a1
            while delta > .pi { delta -= 2 * .pi }
            while delta < -.pi { delta += 2 * .pi }
            let r: CGFloat = 5 * CGFloat(shape.scale)
            stroke.addArc(center: v, radius: r, startAngle: .radians(a1), endAngle: .radians(a1 + delta), clockwise: delta < 0)
            if !shape.text.isEmpty {
                let mid = a1 + delta / 2
                labels.append(Label(text: shape.text, at: CGPoint(x: v.x + cos(mid) * (r + 4.5), y: v.y + sin(mid) * (r + 4.5)),
                                    size: labelSize, usesShapeColor: true))
            }
        case .text?:
            guard let p = points.first, !shape.text.isEmpty else { return }
            labels.append(Label(text: shape.text, at: p, size: 3.6 * CGFloat(shape.scale), usesShapeColor: true))
            drawDuration = 0.35
        case .stamp?:
            guard let p = points.first, let stamp = shape.parsedStamp else { return }
            let height = 16 * CGFloat(shape.scale)
            let art = ChalkStamps.art(for: stamp)
            let transform = CGAffineTransform(translationX: p.x, y: p.y - height / 2).scaledBy(x: height, y: height)
            stroke = art.stroke.applying(transform)
            accent = art.accent?.applying(transform)
            liquid = art.liquid?.applying(transform)
            for text in art.texts {
                labels.append(Label(text: text.text, at: text.at.applying(transform), size: height * text.size, usesShapeColor: true))
            }
            if !shape.text.isEmpty {
                // スタンプの名前は、絵の大きさによらず同じ大きさで絵の下に書く
                labels.append(Label(text: shape.text, at: CGPoint(x: p.x, y: p.y + height / 2 + 2.6), size: 3, usesShapeColor: false))
            }
            drawDuration = 0.8
        case nil:
            return
        }
    }

    private static func addHead(to path: inout Path, tip: CGPoint, from: CGPoint) {
        let angle = atan2(tip.y - from.y, tip.x - from.x)
        let length: CGFloat = 2.6
        for side in [-1.0, 1.0] {
            let a = angle + .pi - side * .pi / 7
            path.move(to: tip)
            path.addLine(to: CGPoint(x: tip.x + cos(a) * length, y: tip.y + sin(a) * length))
        }
    }

    /// 線のラベルは、線の真ん中から少し上（縦の線なら右）に書く
    private static func labelPoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let isVertical = abs(b.y - a.y) > abs(b.x - a.x)
        return isVertical ? CGPoint(x: mid.x + 5, y: mid.y) : CGPoint(x: mid.x, y: mid.y - 3)
    }

    private static func centroid(_ points: [CGPoint]) -> CGPoint {
        let n = CGFloat(points.count)
        return CGPoint(x: points.map(\.x).reduce(0, +) / n, y: points.map(\.y).reduce(0, +) / n)
    }

    /// 点を通るなめらかな線（Catmull-Rom）
    static func smoothCurve(through points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            if let last = points.last { path.addLine(to: last) }
            return path
        }
        for i in 0..<(points.count - 1) {
            let p0 = points[max(i - 1, 0)], p1 = points[i], p2 = points[i + 1], p3 = points[min(i + 2, points.count - 1)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }
}
