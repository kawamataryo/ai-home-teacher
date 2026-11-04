import SwiftUI

/// 自由に描く黒板のスタンプ（#107）。高さ 1 の箱（よこは中心が 0、たては上が 0・下が 1）に描き、使うときに大きくする。
/// 教科書でよく見る形を、チョークの線で描ける簡単な形にした
enum ChalkStamps {
    struct Art {
        var stroke = Path()
        /// 色を付ける所（炎・N 極・温度計の液）
        var accent: Path?
        /// 入れ物の液体（fill のときだけ出す）
        var liquid: Path?
        /// 絵の中の文字（N・S・＋・−・北・文）
        var texts: [(text: String, at: CGPoint, size: CGFloat)] = []
    }

    static func art(for stamp: ChalkDrawing.Stamp) -> Art {
        switch stamp {
        case .beaker: beaker
        case .flask: flask
        case .testTube: testTube
        case .alcoholLamp: alcoholLamp
        case .thermometer: thermometer
        case .graduatedCylinder: graduatedCylinder
        case .magnet: magnet
        case .battery: battery
        case .bulb: bulb
        case .magnifier: magnifier
        case .sun: sun
        case .heatingSetup: heatingSetup
        case .compass: compass
        case .mountain: mountain
        case .japan: japan
        case .mapSchool: Art(texts: [("文", CGPoint(x: 0, y: 0.5), 0.8)])
        case .mapShrine: shrine
        case .mapPostOffice: postOffice
        case .mapRiceField: riceField
        }
    }

    private static func lines(_ segments: [[CGPoint]]) -> Path {
        var path = Path()
        for segment in segments { path.addLines(segment) }
        return path
    }

    private static func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

    // MARK: 理科

    static var beaker: Art {
        var stroke = lines([[p(-0.44, -0.02), p(-0.34, 0.07), p(-0.34, 1), p(0.34, 1), p(0.34, 0)]])
        for y in [0.35, 0.55, 0.75] as [CGFloat] { stroke.addLines([p(0.2, y), p(0.34, y)]) }
        return Art(stroke: stroke, liquid: Path(CGRect(x: -0.34, y: 0.5, width: 0.68, height: 0.5)))
    }

    static var flask: Art {
        let stroke = lines([[p(-0.13, 0), p(-0.1, 0.04), p(-0.1, 0.36), p(-0.42, 1), p(0.42, 1), p(0.1, 0.36), p(0.1, 0.04), p(0.13, 0)]])
        var liquid = Path()
        liquid.addLines([p(-0.24, 0.64), p(0.24, 0.64), p(0.42, 1), p(-0.42, 1)])
        liquid.closeSubpath()
        return Art(stroke: stroke, liquid: liquid)
    }

    static var testTube: Art {
        var stroke = Path()
        stroke.addLines([p(-0.16, 0), p(-0.12, 0.03), p(-0.12, 0.86)])
        stroke.addArc(center: p(0, 0.86), radius: 0.12, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: true)
        stroke.addLines([p(0.12, 0.86), p(0.12, 0.03), p(0.16, 0)])
        var liquid = Path()
        liquid.addLines([p(-0.12, 0.55), p(0.12, 0.55), p(0.12, 0.86)])
        liquid.addArc(center: p(0, 0.86), radius: 0.12, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
        liquid.closeSubpath()
        return Art(stroke: stroke, liquid: liquid)
    }

    static var alcoholLamp: Art {
        var stroke = Path()
        stroke.move(to: p(-0.12, 0.42))
        stroke.addQuadCurve(to: p(-0.42, 0.72), control: p(-0.42, 0.45))
        stroke.addLines([p(-0.42, 0.72), p(-0.42, 1), p(0.42, 1), p(0.42, 0.72)])
        stroke.addQuadCurve(to: p(0.12, 0.42), control: p(0.42, 0.45))
        stroke.addLines([p(0.12, 0.42), p(0.12, 0.34), p(-0.12, 0.34), p(-0.12, 0.42)])
        stroke.addLines([p(0, 0.34), p(0, 0.26)])
        var flame = Path()
        flame.move(to: p(0, 0.27))
        flame.addQuadCurve(to: p(0, -0.05), control: p(-0.16, 0.18))
        flame.addQuadCurve(to: p(0, 0.27), control: p(0.16, 0.18))
        var liquid = Path()
        liquid.addLines([p(-0.42, 0.78), p(0.42, 0.78), p(0.42, 1), p(-0.42, 1)])
        liquid.closeSubpath()
        return Art(stroke: stroke, accent: flame, liquid: liquid)
    }

    static var thermometer: Art {
        var stroke = Path()
        stroke.addRoundedRect(in: CGRect(x: -0.06, y: 0, width: 0.12, height: 0.84), cornerSize: CGSize(width: 0.06, height: 0.06))
        stroke.addEllipse(in: CGRect(x: -0.11, y: 0.8, width: 0.22, height: 0.2))
        for i in 0..<6 { let y = 0.12 + CGFloat(i) * 0.12; stroke.addLines([p(-0.16, y), p(-0.08, y)]) }
        var red = Path(CGRect(x: -0.025, y: 0.4, width: 0.05, height: 0.45))
        red.addEllipse(in: CGRect(x: -0.08, y: 0.83, width: 0.16, height: 0.14))
        return Art(stroke: stroke, accent: red)
    }

    static var graduatedCylinder: Art {
        var stroke = lines([[p(-0.16, 0), p(-0.13, 0.03), p(-0.13, 0.92), p(0.13, 0.92), p(0.13, 0.03), p(0.16, 0)],
                            [p(-0.3, 0.92), p(0.3, 0.92), p(0.3, 1), p(-0.3, 1), p(-0.3, 0.92)]])
        for i in 0..<8 {
            let y = 0.12 + CGFloat(i) * 0.1
            stroke.addLines([p(0.13 - (i % 2 == 0 ? 0.12 : 0.07), y), p(0.13, y)])
        }
        return Art(stroke: stroke, liquid: Path(CGRect(x: -0.13, y: 0.42, width: 0.26, height: 0.5)))
    }

    static var magnet: Art {
        var stroke = Path()
        stroke.move(to: p(-0.42, 0))
        stroke.addLine(to: p(-0.42, 0.58))
        stroke.addArc(center: p(0, 0.58), radius: 0.42, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: true)
        stroke.addLines([p(0.42, 0.58), p(0.42, 0), p(0.16, 0), p(0.16, 0.58)])
        stroke.addArc(center: p(0, 0.58), radius: 0.16, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
        stroke.addLines([p(-0.16, 0.58), p(-0.16, 0), p(-0.42, 0)])
        stroke.addLines([p(-0.42, 0.22), p(-0.16, 0.22)])
        stroke.addLines([p(0.16, 0.22), p(0.42, 0.22)])
        let north = Path(CGRect(x: -0.42, y: 0, width: 0.26, height: 0.22))
        return Art(stroke: stroke, accent: north, texts: [("N", p(-0.29, 0.11), 0.16), ("S", p(0.29, 0.11), 0.16)])
    }

    static var battery: Art {
        var stroke = Path()
        stroke.addRoundedRect(in: CGRect(x: -0.55, y: 0.32, width: 0.95, height: 0.36), cornerSize: CGSize(width: 0.04, height: 0.04))
        stroke.addRect(CGRect(x: 0.4, y: 0.42, width: 0.1, height: 0.16))
        stroke.addLines([p(0.2, 0.32), p(0.2, 0.68)])
        return Art(stroke: stroke, texts: [("＋", p(0.3, 0.5), 0.2), ("－", p(-0.42, 0.5), 0.2)])
    }

    static var bulb: Art {
        var stroke = Path()
        stroke.addArc(center: p(0, 0.34), radius: 0.3, startAngle: .degrees(125), endAngle: .degrees(55), clockwise: false)
        stroke.addLines([p(0.17, 0.59), p(0.15, 0.8), p(-0.15, 0.8), p(-0.17, 0.59)])
        stroke.addLines([p(-0.16, 0.67), p(0.16, 0.67)])
        stroke.addLines([p(-0.15, 0.74), p(0.15, 0.74)])
        stroke.addLines([p(-0.07, 0.8), p(0, 0.9), p(0.07, 0.8)])
        stroke.addLines([p(-0.08, 0.6), p(-0.08, 0.35), p(-0.04, 0.28), p(0, 0.35), p(0.04, 0.28), p(0.08, 0.35), p(0.08, 0.6)])
        return Art(stroke: stroke, liquid: Path(ellipseIn: CGRect(x: -0.3, y: 0.04, width: 0.6, height: 0.6)))
    }

    static var magnifier: Art {
        var stroke = Path(ellipseIn: CGRect(x: -0.42, y: 0.02, width: 0.6, height: 0.6))
        stroke.addLines([p(0.1, 0.55), p(0.42, 0.95)])
        stroke.addLines([p(0.16, 0.5), p(0.48, 0.9)])
        stroke.addLines([p(0.42, 0.95), p(0.48, 0.9)])
        return Art(stroke: stroke)
    }

    static var sun: Art {
        var stroke = Path(ellipseIn: CGRect(x: -0.22, y: 0.28, width: 0.44, height: 0.44))
        for i in 0..<8 {
            let a = CGFloat(i) * .pi / 4
            stroke.addLines([p(cos(a) * 0.3, 0.5 + sin(a) * 0.3), p(cos(a) * 0.46, 0.5 + sin(a) * 0.46)])
        }
        return Art(stroke: stroke, accent: nil)
    }

    /// 上半分にビーカー、真ん中に金網と三脚、下にアルコールランプ
    static var heatingSetup: Art {
        let top = CGAffineTransform(translationX: 0, y: 0).scaledBy(x: 0.48, y: 0.48)
        let bottom = CGAffineTransform(translationX: 0, y: 0.6).scaledBy(x: 0.4, y: 0.4)
        let b = beaker, lamp = alcoholLamp
        var stroke = b.stroke.applying(top)
        stroke.addLines([p(-0.4, 0.5), p(0.4, 0.5)])
        stroke.addLines([p(-0.3, 0.5), p(-0.38, 1)])
        stroke.addLines([p(0.3, 0.5), p(0.38, 1)])
        stroke.addPath(lamp.stroke.applying(bottom))
        return Art(stroke: stroke, accent: lamp.accent?.applying(bottom), liquid: b.liquid?.applying(top))
    }

    // MARK: 地理

    /// 方位記号（上が北。矢じりの半分をぬる）
    static var compass: Art {
        let stroke = lines([[p(0, 0.18), p(0, 1)], [p(-0.28, 0.62), p(0.28, 0.62)], [p(0, 0.18), p(-0.13, 0.48), p(0, 0.4)]])
        var head = Path()
        head.addLines([p(0, 0.18), p(-0.13, 0.48), p(0, 0.4)])
        head.closeSubpath()
        return Art(stroke: stroke, accent: head, texts: [("北", p(0, 0.05), 0.18)])
    }

    static var mountain: Art {
        Art(stroke: lines([[p(-0.6, 1), p(-0.18, 0.12), p(0.02, 0.45), p(0.2, 0.25), p(0.6, 1)],
                           [p(-0.3, 0.38), p(-0.2, 0.45), p(-0.1, 0.36)]]))
    }

    /// 日本列島（北海道・本州・四国・九州）。経度・緯度を箱に直して描く
    static var japan: Art {
        func geo(_ lon: CGFloat, _ lat: CGFloat) -> CGPoint {
            CGPoint(x: (lon - 137.25) / 15, y: (45.7 - lat) / 15)
        }
        let islands: [[(CGFloat, CGFloat)]] = [
            // 北海道
            [(140.0, 41.5), (141.1, 41.8), (141.7, 42.6), (143.3, 42.0), (144.6, 42.9), (145.6, 43.3), (145.2, 44.3),
             (143.8, 44.2), (142.0, 45.5), (141.6, 45.2), (141.4, 43.8), (140.4, 43.3), (139.9, 42.5)],
            // 本州
            [(140.9, 41.5), (141.5, 40.5), (142.0, 39.5), (141.5, 38.4), (141.0, 38.0), (140.9, 37.0), (140.6, 36.0),
             (140.9, 35.7), (140.1, 35.0), (139.7, 35.3), (139.2, 35.2), (138.8, 34.6), (137.0, 34.6), (136.8, 34.3),
             (136.0, 33.5), (135.2, 33.8), (135.1, 34.6), (134.0, 34.7), (133.0, 34.4), (132.0, 33.9), (130.9, 34.0),
             (131.0, 34.4), (131.6, 34.7), (132.6, 35.4), (133.5, 35.5), (134.5, 35.6), (135.5, 35.6), (136.0, 35.9),
             (136.7, 36.8), (137.0, 37.1), (137.4, 36.8), (138.5, 37.4), (139.5, 38.2), (139.9, 39.5), (140.0, 40.6),
             (140.3, 41.2)],
            // 四国
            [(132.4, 33.3), (132.9, 32.8), (133.6, 33.4), (134.3, 33.3), (134.7, 33.8), (134.3, 34.3), (133.5, 34.3),
             (132.7, 33.9)],
            // 九州
            [(129.8, 33.4), (130.9, 33.9), (131.6, 33.4), (131.9, 32.4), (131.3, 31.4), (130.7, 31.0), (130.2, 31.3),
             (130.3, 32.4), (129.7, 32.8)],
        ]
        var stroke = Path()
        for island in islands {
            stroke.addLines(island.map { geo($0.0, $0.1) })
            stroke.closeSubpath()
        }
        return Art(stroke: stroke, liquid: stroke)
    }

    static var shrine: Art {
        Art(stroke: lines([[p(-0.48, 0.2), p(0.48, 0.2)], [p(-0.36, 0.38), p(0.36, 0.38)],
                           [p(-0.24, 0.2), p(-0.28, 1)], [p(0.24, 0.2), p(0.28, 1)]]))
    }

    static var postOffice: Art {
        var stroke = Path(ellipseIn: CGRect(x: -0.45, y: 0.05, width: 0.9, height: 0.9))
        stroke.addLines([p(-0.24, 0.32), p(0.24, 0.32)])
        stroke.addLines([p(-0.24, 0.47), p(0.24, 0.47)])
        stroke.addLines([p(0, 0.47), p(0, 0.78)])
        return Art(stroke: stroke)
    }

    static var riceField: Art {
        Art(stroke: lines([[p(-0.12, 0.25), p(-0.12, 0.8)], [p(0.12, 0.25), p(0.12, 0.8)]]))
    }
}
