import SwiftUI

/// 自由に描く黒板（#107）。図形を 1 つずつチョークで書くように出す（線は始点から伸ばし、文字はふわっと出す）。
/// 段階表示（`boardRevealCount`）のときは、`step` の番号の順に見せる。
struct ChalkDrawingView: View {
    let model: ChalkDrawing
    @Environment(\.boardRevealCount) private var revealCount

    var body: some View {
        let labelPositions = ChalkLabelLayout.positions(for: model)
        GeometryReader { geometry in
            let frame = Self.frame(in: geometry.size)
            ZStack(alignment: .topLeading) {
                ForEach(Array(model.shapes.enumerated()), id: \.offset) { index, shape in
                    let unit = model.revealIndex(of: shape)
                    if unit < revealCount, shape.parsedKind != nil {
                        ChalkShapeView(
                            shape: shape, frame: frame, delay: Self.delay(index: index, unit: unit, in: model),
                            labelPositions: labelPositions[index]
                        )
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
    /// 文字どうしが重ならないようにずらした位置（`ChalkLabelLayout`）
    var labelPositions: [CGPoint] = []
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
            ForEach(Array(geometry.labels.enumerated()), id: \.offset) { i, label in
                Text(label.text)
                    .font(Chalk.font(frame.scale * label.size, weight: .bold))
                    .foregroundStyle(label.usesShapeColor ? color : Chalk.white)
                    .fixedSize()
                    .position(frame.point(i < labelPositions.count ? labelPositions[i] : label.at))
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
        /// 絵の一部の文字（磁石の N・S、乾電池の ＋・－ など）。ずらさない
        var isFixed = false
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
                labels.append(Label(text: text.text, at: text.at.applying(transform), size: height * text.size, usesShapeColor: true, isFixed: true))
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

// MARK: - 文字の置き場所

/// 文字どうしが重ならないように置く（#107）。モデルの座標どおりに置くと、ラベルが重なることがあった。
/// 図形の並び順に置いていき、前に置いた文字と重なったら、近い順に上下（だめなら左右）へずらす。黒板の外には出さない。
/// 段階表示で何が見えているかによらず、図全体で一度だけ決める（見せ方で文字が動かない）
enum ChalkLabelLayout {
    /// 文字の箱（黒板の座標）。日本語は 1 文字が大きさとほぼ同じ幅、英数字はその半分くらい
    static func box(text: String, at point: CGPoint, size: CGFloat) -> CGRect {
        let width = text.reduce(CGFloat(0)) { $0 + ($1.isASCII ? 0.58 : 1.0) } * size + 1
        let height = size * 1.25
        return CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height)
    }

    /// 図形ごとの、文字の位置（`ChalkGeometry.labels` と同じ順）
    static func positions(for model: ChalkDrawing) -> [[CGPoint]] {
        let canvas = CGRect(x: 0, y: 0, width: ChalkDrawing.width, height: ChalkDrawing.height)
        let geometries = model.shapes.map(ChalkGeometry.init(shape:))
        let strokes = geometries.flatMap { samples(of: $0.stroke) }
        var placed: [CGRect] = []
        return geometries.map { geometry in
            geometry.labels.map { label in
                let point = label.isFixed ? label.at : place(label, avoiding: placed, strokes: strokes, in: canvas)
                placed.append(box(text: label.text, at: point, size: label.size))
                return point
            }
        }
    }

    /// 線の上の点（だいたい 1 ずつ）。文字が線にかぶらないかを調べるのに使う
    static func samples(of path: Path) -> [CGPoint] {
        var points: [CGPoint] = []
        var current = CGPoint.zero
        var start = CGPoint.zero
        func line(to end: CGPoint) {
            let n = max(Int((hypot(end.x - current.x, end.y - current.y)).rounded(.up)), 1)
            for i in 1...n {
                let t = CGFloat(i) / CGFloat(n)
                points.append(CGPoint(x: current.x + (end.x - current.x) * t, y: current.y + (end.y - current.y) * t))
            }
            current = end
        }
        path.forEach { element in
            switch element {
            case .move(let p):
                current = p
                start = p
                points.append(p)
            case .line(let p):
                line(to: p)
            case .quadCurve(let p, let c):
                let from = current
                for i in 1...8 {
                    let t = CGFloat(i) / 8, u = 1 - t
                    let q = CGPoint(x: u * u * from.x + 2 * u * t * c.x + t * t * p.x, y: u * u * from.y + 2 * u * t * c.y + t * t * p.y)
                    line(to: q)
                }
            case .curve(let p, let c1, let c2):
                let from = current
                for i in 1...10 {
                    let t = CGFloat(i) / 10, u = 1 - t
                    let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
                    line(to: CGPoint(x: a * from.x + b * c1.x + c * c2.x + d * p.x, y: a * from.y + b * c1.y + c * c2.y + d * p.y))
                }
            case .closeSubpath:
                line(to: start)
            }
        }
        return points
    }

    /// 前に置いた文字と重ならず、線にもかぶらない、いちばん近い場所。線を避けられなければ文字どうしだけ避ける
    static func place(_ label: ChalkGeometry.Label, avoiding placed: [CGRect], strokes: [CGPoint], in canvas: CGRect) -> CGPoint {
        let original = box(text: label.text, at: label.at, size: label.size)
        let step = original.height * 0.55
        var offsets: [CGPoint] = [.zero]
        for k in 1...8 {
            let d = CGFloat(k) * step
            offsets += [CGPoint(x: 0, y: d), CGPoint(x: 0, y: -d)]
        }
        for k in 1...6 {
            let d = CGFloat(k) * step * 1.5
            offsets += [CGPoint(x: d, y: 0), CGPoint(x: -d, y: 0)]
        }
        var fallback: CGPoint?
        for offset in offsets {
            let point = CGPoint(x: label.at.x + offset.x, y: label.at.y + offset.y)
            let rect = box(text: label.text, at: point, size: label.size)
            let inside = rect.minX >= canvas.minX - 2 && rect.maxX <= canvas.maxX + 2 && rect.minY >= canvas.minY - 1 && rect.maxY <= canvas.maxY + 1
            // 少しだけ触れるのは許す（ぎっしり並べた文字を大きく動かさない）
            let tight = rect.insetBy(dx: 0.4, dy: 0.3)
            guard inside, !placed.contains(where: { $0.insetBy(dx: 0.4, dy: 0.3).intersects(tight) }) else { continue }
            if !strokes.contains(where: { tight.contains($0) }) { return point }
            // 線を避けるのは近くだけ（遠くへ飛ばすと、何のラベルかわからなくなる）
            if fallback == nil { fallback = point }
            if abs(offset.x) + abs(offset.y) > step * 4 { break }
        }
        return fallback ?? label.at
    }
}
