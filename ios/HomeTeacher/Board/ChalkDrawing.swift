import CoreGraphics
import Foundation

/// 自由に描く黒板（#107）。決まった部品で表せない図（理科の実験道具・回路・地図・図形）を、線・図形・文字・スタンプで描く。
///
/// 座標は よこ 0〜100・たて 0〜70（左上が 0,0。下へ行くほど y が大きい）。画面の大きさに合わせて縮める。
/// SVG より短く書けるので、会話（Haiku）でも返事の長さの上限で切れにくい。
struct ChalkDrawing: BoardComponentModel {
    static let width: Double = 100
    static let height: Double = 70

    struct Shape: Codable, Equatable, Sendable {
        /// 図形の種類（`Kind`）。知らない種類は描かない
        var kind: String
        /// 点の列 [[x, y], …]。線・矢印は始点と終点、四角は対角の2点、円・文字・スタンプは中心の1点
        var points: [[Double]]
        /// 円の半径
        var radius: Double
        /// 文字（text）・ラベル（そのほかの図形のそばに書く）
        var text: String
        /// スタンプの名前（`Stamp`）
        var stamp: String
        /// 大きさの倍率（文字・スタンプ。0 なら 1）
        var size: Double
        /// チョークの色（white・yellow・pink・blue）
        var color: String
        var dashed: Bool
        /// 中をうすくぬる（四角・円・多角形）。入れ物のスタンプなら液体を入れる
        var fill: Bool
        /// 何番目に見せるか（1 から。0 なら 1）。同じ番号はまとめて出る
        var step: Int

        init(kind: Kind, points: [[Double]] = [], radius: Double = 0, text: String = "", stamp: Stamp? = nil,
             size: Double = 0, color: String = "white", dashed: Bool = false, fill: Bool = false, step: Int = 1) {
            self.kind = kind.rawValue
            self.points = points
            self.radius = radius
            self.text = text
            self.stamp = stamp?.rawValue ?? ""
            self.size = size
            self.color = color
            self.dashed = dashed
            self.fill = fill
            self.step = step
        }

        var parsedKind: Kind? { Kind(rawValue: kind) }
        var parsedStamp: Stamp? { Stamp(rawValue: stamp) }
        var scale: Double { size > 0 ? min(size, 4) : 1 }
        var revealStep: Int { max(step, 1) }

        /// 座標を黒板の中に収めた点（数でない値・足りない座標は捨てる）
        var cgPoints: [CGPoint] {
            points.compactMap { p in
                guard p.count >= 2, p[0].isFinite, p[1].isFinite else { return nil }
                return CGPoint(x: min(max(p[0], -10), ChalkDrawing.width + 10), y: min(max(p[1], -10), ChalkDrawing.height + 10))
            }
        }
    }

    enum Kind: String, CaseIterable, Sendable {
        case line, arrow
        case doubleArrow = "double_arrow"
        case rect, circle, polygon, polyline, curve, text, stamp
        /// 角の印（points: 頂点・一方の辺の点・もう一方の辺の点）
        case angle
    }

    /// 用意してある絵。中心（points の 1 点）に、高さ 16（size 倍）で描く
    enum Stamp: String, CaseIterable, Sendable {
        // 理科
        case beaker, flask
        case testTube = "test_tube"
        case alcoholLamp = "alcohol_lamp"
        case thermometer
        case graduatedCylinder = "graduated_cylinder"
        case magnet, battery, bulb, magnifier, sun
        /// 三脚と金網の上のビーカーを、アルコールランプであたためる（よく使う組み合わせ）
        case heatingSetup = "heating_setup"
        // 地理
        case compass, mountain, japan
        case mapSchool = "map_school"
        case mapShrine = "map_shrine"
        case mapPostOffice = "map_post_office"
        case mapRiceField = "map_rice_field"

        /// 一覧に書く短い名前（かっこの説明と「地図記号」を除く）
        var shortName: String {
            if self == .heatingSetup { return "加熱の道具" }
            let base = japaneseName.components(separatedBy: "（").first ?? japaneseName
            return base.components(separatedBy: " ").last ?? base
        }

        var japaneseName: String {
            switch self {
            case .beaker: "ビーカー"
            case .flask: "三角フラスコ"
            case .testTube: "試験管"
            case .alcoholLamp: "アルコールランプ"
            case .thermometer: "温度計"
            case .graduatedCylinder: "メスシリンダー"
            case .magnet: "U字形磁石"
            case .battery: "乾電池"
            case .bulb: "豆電球"
            case .magnifier: "虫めがね"
            case .sun: "太陽"
            case .heatingSetup: "ビーカーをアルコールランプであたためる（三脚・金網つき）"
            case .compass: "方位記号（上が北）"
            case .mountain: "山"
            case .japan: "日本列島の形"
            case .mapSchool: "地図記号 学校"
            case .mapShrine: "地図記号 神社"
            case .mapPostOffice: "地図記号 郵便局"
            case .mapRiceField: "地図記号 田"
            }
        }
    }

    var shapes: [Shape]

    static let kind = BoardComponent.Kind.chalkDrawing
    static var usage: String {
        "自由に描く黒板。決まった部品で表せない図（理科の実験道具・回路・てこ・植物、地図・方位、図形）を、線・図形・文字・スタンプで描く。"
            + "座標は よこ0〜100・たて0〜70（左上が0,0、下へ行くほど y が大きい）。図形は6〜15個まで。kind と points のほかは使うときだけ書く"
    }

    static var schemaProperties: [(String, JSONValue)] {
        let kinds = Kind.allCases.map(\.rawValue).joined(separator: "・")
        let stamps = Stamp.allCases.map { "\($0.rawValue)（\($0.japaneseName)）" }.joined(separator: "、")
        return [("shapes", Schema.array(Schema.object([
            ("kind", Schema.string("図形の種類：\(kinds)。angle は角の印（points は頂点・辺の上の点・もう一方の辺の上の点）")),
            ("points", Schema.array(Schema.array(Schema.number("座標"), description: "[x, y]"),
                                    description: "点の列。line・arrow・double_arrow は始点と終点、rect は対角の2点、polygon・polyline・curve は3点以上、circle・text・stamp は中心の1点")),
            ("radius", Schema.number("circle の半径（例：8）")),
            ("text", Schema.string("text の文字。ほかの図形では、そばに書くラベル（15文字以内。答えは書かない）")),
            ("stamp", Schema.string("kind が stamp のときの絵：\(stamps)")),
            ("size", Schema.number("文字・スタンプの大きさの倍率（ふつうは 1。0.5〜3）")),
            ("color", Schema.string("チョークの色：white・yellow（大事なところ）・pink（気をつけるところ）・blue（水・補助線）")),
            ("dashed", Schema.boolean("点線にする（補助線・見えない線・動いたあと）")),
            ("fill", Schema.boolean("中をうすくぬる。ビーカーなど入れ物のスタンプなら液体を入れる")),
            ("step", Schema.integer("何番目に見せるか（1から）。話す順に番号をふると、1つずつ見せられる")),
        // kind と points のほかは、使うときだけ書く（全部を必須にすると毎回すべて書き、会話の返事の上限に近づいた。#107）
        ], required: ["kind", "points"]), description: "描く図形（話す順に並べる）。kind と points のほかは使うときだけ書く"))]
    }

    /// 段階表示の単位（step の番号の数）
    var stepCount: Int { Set(shapes.map(\.revealStep)).count }

    /// 単位の番号（0 から）。step を小さい順に詰めたもの
    func revealIndex(of shape: Shape) -> Int {
        let steps = Set(shapes.map(\.revealStep)).sorted()
        return steps.firstIndex(of: shape.revealStep) ?? 0
    }
}
