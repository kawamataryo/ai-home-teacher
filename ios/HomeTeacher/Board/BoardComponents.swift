import Foundation

/// 黒板の部品のモデル。JSON Schema は各モデルの隣に置き、ここだけを正とする。
/// JSON のキーは snake_case（`BoardTools` の decoder/encoder が camelCase と変換する）。
protocol BoardComponentModel: Codable, Equatable, Sendable {
    static var kind: BoardComponent.Kind { get }
    /// Claude に見せる「この部品をいつ使うか」。
    static var usage: String { get }
    /// `type` 以外のプロパティ（宣言順に required になる）。
    static var schemaProperties: [(String, JSONValue)] { get }
}

extension BoardComponentModel {
    static var schema: JSONValue {
        Schema.object([("type", Schema.constant(kind.rawValue))] + schemaProperties, description: usage)
    }
}

/// 黒板に出す部品。JSON では `type` で見分ける。
enum BoardComponent: Equatable, Sendable {
    case stepCards(StepCards)
    case numberLine(NumberLine)
    case areaDiagram(AreaDiagram)
    case segmentDiagram(SegmentDiagram)
    case table(BoardTable)
    case barChart(BarChart)
    case highlightImage(HighlightImage)
    case essayOutline(EssayOutline)

    enum Kind: String, CaseIterable, Sendable {
        case stepCards = "step_cards"
        case numberLine = "number_line"
        case areaDiagram = "area_diagram"
        case segmentDiagram = "segment_diagram"
        case table
        case barChart = "bar_chart"
        case highlightImage = "highlight_image"
        case essayOutline = "essay_outline"

        var model: any BoardComponentModel.Type {
            switch self {
            case .stepCards: StepCards.self
            case .numberLine: NumberLine.self
            case .areaDiagram: AreaDiagram.self
            case .segmentDiagram: SegmentDiagram.self
            case .table: BoardTable.self
            case .barChart: BarChart.self
            case .highlightImage: HighlightImage.self
            case .essayOutline: EssayOutline.self
            }
        }
    }

    var kind: Kind {
        switch self {
        case .stepCards: .stepCards
        case .numberLine: .numberLine
        case .areaDiagram: .areaDiagram
        case .segmentDiagram: .segmentDiagram
        case .table: .table
        case .barChart: .barChart
        case .highlightImage: .highlightImage
        case .essayOutline: .essayOutline
        }
    }

    /// 全部品の anyOf。
    static var schema: JSONValue {
        Schema.anyOf(Kind.allCases.map { $0.model.schema }, description: "黒板に出す部品。type で種類を選ぶ")
    }
}

extension BoardComponent: Codable {
    private enum TypeKey: String, CodingKey { case type }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: TypeKey.self)
        let raw = try c.decode(String.self, forKey: .type)
        guard let kind = Kind(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "未知の部品: \(raw)")
        }
        switch kind {
        case .stepCards: self = .stepCards(try StepCards(from: decoder))
        case .numberLine: self = .numberLine(try NumberLine(from: decoder))
        case .areaDiagram: self = .areaDiagram(try AreaDiagram(from: decoder))
        case .segmentDiagram: self = .segmentDiagram(try SegmentDiagram(from: decoder))
        case .table: self = .table(try BoardTable(from: decoder))
        case .barChart: self = .barChart(try BarChart(from: decoder))
        case .highlightImage: self = .highlightImage(try HighlightImage(from: decoder))
        case .essayOutline: self = .essayOutline(try EssayOutline(from: decoder))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: TypeKey.self)
        try c.encode(kind.rawValue, forKey: .type)
        switch self {
        case .stepCards(let m): try m.encode(to: encoder)
        case .numberLine(let m): try m.encode(to: encoder)
        case .areaDiagram(let m): try m.encode(to: encoder)
        case .segmentDiagram(let m): try m.encode(to: encoder)
        case .table(let m): try m.encode(to: encoder)
        case .barChart(let m): try m.encode(to: encoder)
        case .highlightImage(let m): try m.encode(to: encoder)
        case .essayOutline(let m): try m.encode(to: encoder)
        }
    }
}

// MARK: - 各部品

/// 手順カード：解き方や考える順番を 1 枚ずつ見せる。
struct StepCards: BoardComponentModel {
    struct Step: Codable, Equatable, Sendable {
        var heading: String
        var detail: String
    }
    var steps: [Step]

    static let kind = BoardComponent.Kind.stepCards
    static let usage = "手順カード。考える順番を短いカードで見せる。最後のカードは子どもに考えさせる問いかけにする"
    static var schemaProperties: [(String, JSONValue)] {
        [("steps", Schema.array(Schema.object([
            ("heading", Schema.string("カードの見出し（例：何を聞かれている？）")),
            ("detail", Schema.string("説明。1〜2文")),
        ]), description: "カード（2〜5枚）"))]
    }
}

/// 数直線：分数・小数・割合の位置や、範囲を示す。
struct NumberLine: BoardComponentModel {
    struct Mark: Codable, Equatable, Sendable {
        var value: Double
        var label: String
    }
    struct Span: Codable, Equatable, Sendable {
        var from: Double
        var to: Double
        var label: String
    }
    var min: Double
    var max: Double
    var step: Double
    var unit: String
    var marks: [Mark]
    var ranges: [Span]

    static let kind = BoardComponent.Kind.numberLine
    static let usage = "数直線。数の大小、分数・小数の位置、割合や差の幅を示す"
    static var schemaProperties: [(String, JSONValue)] {
        [
            ("min", Schema.number("左端の値")),
            ("max", Schema.number("右端の値（min より大きい）")),
            ("step", Schema.number("目盛りの間隔（0 より大きい）")),
            ("unit", Schema.string("単位（例：m、%）。無ければ空文字")),
            ("marks", Schema.array(Schema.object([
                ("value", Schema.number("印を付ける値")),
                ("label", Schema.string("印の名前（例：A、□）")),
            ]), description: "点で示す値")),
            ("ranges", Schema.array(Schema.object([
                ("from", Schema.number("始まりの値")),
                ("to", Schema.number("終わりの値")),
                ("label", Schema.string("幅の説明（例：差、？）")),
            ]), description: "かっこで示す幅。無ければ空配列")),
        ]
    }
}

/// 面積図：たて×よこ で考える問題（平均、つるかめ算、単位量あたり）。
struct AreaDiagram: BoardComponentModel {
    struct Part: Codable, Equatable, Sendable {
        var width: Double
        var height: Double
        var label: String
        var widthLabel: String
        var heightLabel: String
    }
    var parts: [Part]
    var totalLabel: String

    static let kind = BoardComponent.Kind.areaDiagram
    static let usage = "面積図。たて×よこ＝面積 で考える問題（平均、つるかめ算、単位量あたりの大きさ）。長方形を左から並べる"
    static var schemaProperties: [(String, JSONValue)] {
        [
            ("parts", Schema.array(Schema.object([
                ("width", Schema.number("よこの長さ（図の比率。0 より大きい）")),
                ("height", Schema.number("たての長さ（図の比率。0 より大きい）")),
                ("label", Schema.string("長方形の中に書く文字（例：面積＝？）")),
                ("width_label", Schema.string("よこの辺の説明（例：3人）")),
                ("height_label", Schema.string("たての辺の説明（例：80点）")),
            ]), description: "左から並べる長方形（1〜4個）")),
            ("total_label", Schema.string("全体の説明（例：合わせて5人）。無ければ空文字")),
        ]
    }
}

/// 線分図：量の関係（和差算、割合、倍）をテープで比べる。
struct SegmentDiagram: BoardComponentModel {
    struct Segment: Codable, Equatable, Sendable {
        var length: Double
        var label: String
    }
    struct Bar: Codable, Equatable, Sendable {
        var name: String
        var segments: [Segment]
        var totalLabel: String
    }
    var bars: [Bar]

    static let kind = BoardComponent.Kind.segmentDiagram
    static let usage = "線分図。2〜3つの量をテープで並べて比べる（和と差、何倍、割合）。長さは全テープ共通の比率"
    static var schemaProperties: [(String, JSONValue)] {
        [("bars", Schema.array(Schema.object([
            ("name", Schema.string("テープの名前（例：兄、もとの量）")),
            ("segments", Schema.array(Schema.object([
                ("length", Schema.number("区切りの長さ（比率。0 より大きい）")),
                ("label", Schema.string("区切りの上に書く文字（例：120円、？）")),
            ]), description: "左から並べる区切り")),
            ("total_label", Schema.string("テープ全体の説明。無ければ空文字")),
        ]), description: "上から並べるテープ（1〜4本）"))]
    }
}

/// 表：資料の読み取りや、きまりを見つける問題。
struct BoardTable: BoardComponentModel {
    struct Cell: Codable, Equatable, Sendable {
        var row: Int
        var column: Int
    }
    var headers: [String]
    var rows: [[String]]
    var highlightCells: [Cell]

    static let kind = BoardComponent.Kind.table
    static let usage = "表。資料の読み取り、ともなって変わる量、きまり探し。注目してほしいマスを強調できる"
    static var schemaProperties: [(String, JSONValue)] {
        [
            ("headers", Schema.array(Schema.string("見出し"), description: "1行目の見出し")),
            ("rows", Schema.array(Schema.array(Schema.string("マスの文字。空欄は空文字、考えさせるマスは？"), description: "1行分"),
                                  description: "見出しの下の行")),
            ("highlight_cells", Schema.array(Schema.object([
                ("row", Schema.integer("rows の何行目か（0 始まり）")),
                ("column", Schema.integer("何列目か（0 始まり）")),
            ]), description: "強調するマス。無ければ空配列")),
        ]
    }
}

/// 棒グラフ：資料の読み取り、比べる。
struct BarChart: BoardComponentModel {
    struct Bar: Codable, Equatable, Sendable {
        var label: String
        var value: Double
        var highlighted: Bool
    }
    var unit: String
    var bars: [Bar]

    static let kind = BoardComponent.Kind.barChart
    static let usage = "棒グラフ。量を比べる、グラフの読み取り。注目してほしい棒を強調できる"
    static var schemaProperties: [(String, JSONValue)] {
        [
            ("unit", Schema.string("たて軸の単位（例：人、mm）")),
            ("bars", Schema.array(Schema.object([
                ("label", Schema.string("横軸の項目名")),
                ("value", Schema.number("値（0 以上）")),
                ("highlighted", Schema.boolean("注目してほしい棒なら true")),
            ]), description: "左から並べる棒（2〜8本）")),
        ]
    }
}

/// 撮影した写真の一部を囲む。「ここを見て」を示す。
struct HighlightImage: BoardComponentModel {
    struct Region: Codable, Equatable, Sendable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double
        var label: String
    }
    var imageId: String
    var regions: [Region]

    static let kind = BoardComponent.Kind.highlightImage
    static let usage = "撮影した写真の一部を囲んで「ここを見て」と示す。座標は写真の幅・高さを 1 とした割合（左上が 0,0）"
    static var schemaProperties: [(String, JSONValue)] {
        [
            ("image_id", Schema.string("会話で渡された写真の ID")),
            ("regions", Schema.array(Schema.object([
                ("x", Schema.number("囲みの左端（0〜1）")),
                ("y", Schema.number("囲みの上端（0〜1）")),
                ("width", Schema.number("囲みの幅（0〜1）")),
                ("height", Schema.number("囲みの高さ（0〜1）")),
                ("label", Schema.string("囲みに付ける短い言葉（例：ここの単位）")),
            ]), description: "囲む場所（1〜3個）")),
        ]
    }
}

/// 作文の構成メモ：はじめ・なか・おわり などに書くことを整理する。
struct EssayOutline: BoardComponentModel {
    struct Section: Codable, Equatable, Sendable {
        var heading: String
        var points: [String]
    }
    var theme: String
    var sections: [Section]

    static let kind = BoardComponent.Kind.essayOutline
    static let usage = "作文の構成メモ。子どもが話した言葉を使って、はじめ・なか・おわり に書くことを整理する"
    static var schemaProperties: [(String, JSONValue)] {
        [
            ("theme", Schema.string("作文の題やテーマ")),
            ("sections", Schema.array(Schema.object([
                ("heading", Schema.string("段落の名前（例：はじめ）")),
                ("points", Schema.array(Schema.string("書くこと（短く）"), description: "書くこと。まだ決まっていなければ「？」")),
            ]), description: "段落（2〜4個）")),
        ]
    }
}
