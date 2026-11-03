import Foundation

/// 黒板に出す中身。
enum BoardContent: Equatable, Sendable {
    /// ネイティブ部品（show_board）。
    case component(title: String, BoardComponent)
    /// カタログで表せない図（render_svg）。中身は SVGSanitizer を通したもの。
    case svg(SVGBoard)
    /// 図を出せなかったときの文字での代わり。
    case text(String)
}

/// show_board ツールの入力。
struct ShowBoardInput: Codable, Equatable, Sendable {
    var title: String
    var component: BoardComponent

    static var schema: JSONValue {
        Schema.object([
            ("title", Schema.string("黒板の見出し（短く。例：何を聞かれているかな？）")),
            ("component", BoardComponent.schema),
        ])
    }
}

/// render_svg で出す図。
struct SVGBoard: Equatable, Sendable {
    /// 無害化済みの SVG。
    var svg: String
    var caption: String
}

/// render_svg ツールの入力。
struct RenderSVGInput: Codable, Equatable, Sendable {
    var svg: String
    var caption: String

    init(svg: String, caption: String) {
        self.svg = svg
        self.caption = caption
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        svg = try c.decode(String.self, forKey: .svg)
        caption = try c.decodeIfPresent(String.self, forKey: .caption) ?? ""
    }

    static var schema: JSONValue {
        Schema.object([
            ("svg", Schema.string("自己完結の SVG 文字列。<svg> から始め、viewBox を付ける")),
            ("caption", Schema.string("図の下に出す短い説明。無ければ空文字")),
        ])
    }
}

/// Claude（Messages API）に渡す黒板ツールの定義と、tool_use の入力の読み取り。
enum BoardTools {
    static let showBoardName = "show_board"

    static let showBoardDescription = """
        先生の発話と一緒に、黒板に図を出す。部品を1つ選んで中身を指定する。
        黒板には考え方・見る場所・手順を出し、正答（答えの数字や言葉）は書かない。答えのマスや部分は「？」にする。
        子どもが読めるように、小学5年生までの漢字と短い言葉で書く。
        """

    /// show_board のツール定義（`tools` 配列の1要素）。
    static var showBoard: JSONValue {
        .object([
            "name": .string(showBoardName),
            "description": .string(showBoardDescription),
            "strict": .bool(true),
            "input_schema": ShowBoardInput.schema,
        ])
    }

    static let renderSVGName = "render_svg"

    static let renderSVGDescription = """
        show_board の部品で表せない図（図形の角度・展開図・回転など）を、自己完結の SVG で黒板に出す。
        外部の画像・フォント・リンク、script、イベント属性（onclick など）、foreignObject は使わない（取り除かれる）。
        動きは CSS アニメーションだけ。<svg> に viewBox を付け、黒板（暗い緑）の上で見える明るい色で描く。
        答えの数字や言葉は書かず、求めるところは「？」にする。
        """

    /// render_svg のツール定義。
    static var renderSVG: JSONValue {
        .object([
            "name": .string(renderSVGName),
            "description": .string(renderSVGDescription),
            "strict": .bool(true),
            "input_schema": RenderSVGInput.schema,
        ])
    }

    /// 黒板のツールすべて。
    static var all: [JSONValue] { [showBoard, renderSVG] }

    /// `tools` にそのまま入れられる JSON（キー順固定）。
    static func toolsJSON() throws -> Data {
        try JSONValue.array(all).jsonData()
    }

    static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    /// tool_use を黒板の中身にする。読めないときはクラッシュせず文字にする。
    static func content(toolName: String, input: Data) -> BoardContent {
        switch toolName {
        case showBoardName:
            if let decoded = try? makeDecoder().decode(ShowBoardInput.self, from: input) {
                return .component(title: decoded.title, decoded.component)
            }
        case renderSVGName:
            guard let decoded = try? makeDecoder().decode(RenderSVGInput.self, from: input) else { break }
            switch SVGSanitizer.sanitize(decoded.svg) {
            case .success(let s):
                return .svg(SVGBoard(svg: s.svg, caption: decoded.caption))
            case .failure:
                // SVG は子どもに読めないので、説明だけ出す
                return .text(decoded.caption.isEmpty ? notice : decoded.caption)
            }
        default:
            break
        }
        return .text(fallbackText(from: input))
    }

    static func content(toolName: String, input: JSONValue) -> BoardContent {
        content(toolName: toolName, input: (try? input.jsonData()) ?? Data())
    }

    /// 図にできなかった入力から、読める文字だけを拾って並べる。
    static func fallbackText(from input: Data) -> String {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: input) else {
            return String(data: input, encoding: .utf8).map { $0.isEmpty ? notice : $0 } ?? notice
        }
        var lines: [String] = []
        collectStrings(json, into: &lines)
        return lines.isEmpty ? notice : lines.joined(separator: "\n")
    }

    static let notice = "（図をうまく出せなかったよ）"

    /// 部品の種類や ID のような、子どもに見せても意味のない値は拾わない。
    private static let ignoredKeys: Set<String> = ["type", "image_id", "svg"]

    private static func priority(_ key: String) -> Int {
        ["title", "theme", "name", "heading"].firstIndex(of: key) ?? 99
    }

    private static func collectStrings(_ value: JSONValue, into lines: inout [String]) {
        switch value {
        case .string(let s):
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { lines.append(t) }
        case .array(let a):
            a.forEach { collectStrings($0, into: &lines) }
        case .object(let o):
            // 見出しになりやすいキーを先に出す
            let keys = o.keys.sorted { (priority($0), $0) < (priority($1), $1) }
            for key in keys where !ignoredKeys.contains(key) {
                collectStrings(o[key]!, into: &lines)
            }
        default:
            break
        }
    }
}
