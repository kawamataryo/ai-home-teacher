import Foundation

/// 黒板の図にも答えを書かない（#70）。図の文字を正答と照合し、含まれていたらその文字だけを「？」にする。
///
/// 図ごと捨てないのは、問題の資料（表の数など）が答えの数を含むことがあるため。消すのは答えを含む文字のところだけ。
/// 数の値（棒の高さ・目盛りの位置）は文字として見せないものもあるので触らない。棒グラフの値の文字はそのまま出る点に注意。
extension AnswerLeakGuard {
    struct MaskedBoard: Equatable, Sendable {
        var content: BoardContent
        /// 「？」にした文字の数
        var maskedCount: Int
    }

    static let maskText = "？"

    func mask(_ content: BoardContent) -> MaskedBoard {
        guard isActive else { return MaskedBoard(content: content, maskedCount: 0) }
        var count = 0
        let screen: (String) -> String = { text in
            guard case .blocked = check(text) else { return text }
            count += 1
            return Self.maskText
        }
        switch content {
        case .component(let title, let component):
            let input = ShowBoardInput(title: title, component: component)
            guard let data = try? BoardTools.makeEncoder().encode(input),
                  let json = try? JSONDecoder().decode(JSONValue.self, from: data)
            else { return MaskedBoard(content: content, maskedCount: 0) }
            let masked = Self.mapStrings(json, transform: screen)
            guard count > 0,
                  let maskedData = try? masked.jsonData(),
                  let decoded = try? BoardTools.makeDecoder().decode(ShowBoardInput.self, from: maskedData)
            else { return MaskedBoard(content: content, maskedCount: 0) }
            return MaskedBoard(content: .component(title: decoded.title, decoded.component), maskedCount: count)
        case .svg(let board):
            let svg = Self.mapSVGText(board.svg, transform: screen)
            let caption = screen(board.caption)
            return MaskedBoard(content: .svg(SVGBoard(svg: svg, caption: caption)), maskedCount: count)
        case .referenceImage(var image):
            // 写真は変えられないので、文字だけ見る
            image.caption = screen(image.caption)
            return MaskedBoard(content: .referenceImage(image), maskedCount: count)
        case .text(let text):
            let lines = text.components(separatedBy: "\n").map(screen)
            return MaskedBoard(content: .text(lines.joined(separator: "\n")), maskedCount: count)
        }
    }

    /// 部品の種類や写真の ID は答えと関係ないので触らない。
    /// 自由に描く黒板（#107）の図形の種類・スタンプの名前・色も触らない。
    private static let untouchedKeys: Set<String> = ["type", "image_id", "kind", "stamp", "color"]

    private static func mapStrings(_ value: JSONValue, key: String? = nil, transform: (String) -> String) -> JSONValue {
        switch value {
        case .string(let s):
            if let key, untouchedKeys.contains(key) { return value }
            return .string(transform(s))
        case .array(let items):
            return .array(items.map { mapStrings($0, key: key, transform: transform) })
        case .object(let o):
            return .object(o.reduce(into: [:]) { out, pair in
                out[pair.key] = mapStrings(pair.value, key: pair.key, transform: transform)
            })
        default:
            return value
        }
    }

    /// SVG の文字（タグの間の文字）だけを照合する。`<style>` の中は CSS なので触らない。
    static func mapSVGText(_ svg: String, transform: (String) -> String) -> String {
        var out = ""
        var rest = Substring(svg)
        while let open = rest.firstIndex(of: "<") {
            let text = String(rest[..<open])
            out += text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? text : transform(text)
            guard let close = rest[open...].firstIndex(of: ">") else {
                out += rest[open...]
                return out
            }
            let tag = rest[open...close]
            out += tag
            rest = rest[rest.index(after: close)...]
            if tag.lowercased().hasPrefix("<style"), let end = rest.range(of: "</style>", options: .caseInsensitive) {
                out += rest[..<end.lowerBound]
                rest = rest[end.lowerBound...]
            }
        }
        let tail = String(rest)
        out += tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? tail : transform(tail)
        return out
    }
}
