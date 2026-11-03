import Foundation

/// render_svg で受け取った SVG を、許可した要素だけで組み立て直す。
/// script・イベント属性・foreignObject・外部への参照は取り除き、XML として読めないものは受け付けない。
/// WKWebView 側でも JavaScript 無効・CSP・通信遮断をしているので、ここは一段目の守り。
enum SVGSanitizer {
    struct Sanitized: Equatable, Sendable {
        var svg: String
        /// 取り除いたもの（テストと記録用）。
        var removed: [String]
    }

    enum Failure: Error, Equatable {
        case tooLarge
        case doctype
        case notXML(String)
        case rootIsNotSVG
    }

    static let maxBytes = 200_000

    /// 図形を描くための要素だけ許可する。アニメーションは CSS のみ（SMIL の animate/set は使わせない）。
    static let allowedElements: Set<String> = [
        "svg", "g", "defs", "symbol", "use", "title", "desc", "style",
        "path", "rect", "circle", "ellipse", "line", "polyline", "polygon",
        "text", "tspan", "textPath",
        "linearGradient", "radialGradient", "stop", "pattern", "marker", "clipPath", "mask",
    ]

    static func sanitize(_ input: String) -> Result<Sanitized, Failure> {
        guard input.utf8.count <= maxBytes else { return .failure(.tooLarge) }
        // DOCTYPE／ENTITY は使い道が無く、実体参照の膨張（billion laughs）の入口になるので受け付けない
        let lowered = input.lowercased()
        guard !lowered.contains("<!doctype"), !lowered.contains("<!entity") else { return .failure(.doctype) }

        let builder = Builder()
        let parser = XMLParser(data: Data(input.utf8))
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = builder
        guard parser.parse() else {
            return .failure(.notXML(parser.parserError?.localizedDescription ?? "unknown"))
        }
        guard builder.rootName == "svg" else { return .failure(.rootIsNotSVG) }
        return .success(Sanitized(svg: builder.output, removed: builder.removed))
    }

    // MARK: - 属性・CSS の検査

    /// 属性を残してよいか。
    static func isAllowedAttribute(name: String, value: String) -> Bool {
        let n = name.lowercased()
        if n.hasPrefix("on") { return false }
        if n == "href" || n == "xlink:href" { return value.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        // xmlns 系以外の名前空間付き属性は不要
        if n.contains(":"), !(n.hasPrefix("xmlns") || n.hasPrefix("xml:")) { return false }
        if n == "style" { return isSafeCSS(value) }
        return isSafeValue(value)
    }

    /// 属性値に外部参照やスクリプトが紛れていないか。
    static func isSafeValue(_ value: String) -> Bool {
        let v = value.lowercased().filter { !$0.isWhitespace }
        if v.contains("javascript:") || v.contains("vbscript:") || v.contains("data:text/html") { return false }
        return onlyLocalURLs(v)
    }

    /// CSS（style 属性・style 要素）に外部読み込みが無いか。
    static func isSafeCSS(_ css: String) -> Bool {
        let v = css.lowercased().filter { !$0.isWhitespace }
        if v.contains("@import") || v.contains("expression(") || v.contains("\\") { return false }
        return isSafeValue(v)
    }

    /// `url(...)` があれば、文書内の参照（`url(#id)`）だけ許可する。
    private static func onlyLocalURLs(_ v: String) -> Bool {
        var rest = Substring(v)
        while let r = rest.range(of: "url(") {
            let after = rest[r.upperBound...].drop { $0 == "'" || $0 == "\"" }
            guard after.hasPrefix("#") else { return false }
            rest = after
        }
        return true
    }

    // MARK: - 組み立て直し

    private final class Builder: NSObject, XMLParserDelegate {
        var output = ""
        var removed: [String] = []
        var rootName: String?
        /// 取り除いている要素の深さ（0 なら出力中）。
        private var skipDepth = 0
        private var stack: [String] = []
        /// style 要素の中身。文字は分割して届く（&#64; などの参照ごとに切れる）ので、閉じたときにまとめて検査する。
        private var styleBuffer = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            if rootName == nil { rootName = name }
            if skipDepth > 0 { skipDepth += 1; return }
            guard SVGSanitizer.allowedElements.contains(name) else {
                removed.append("<\(name)>")
                skipDepth = 1
                return
            }
            stack.append(name)
            output += "<\(name)"
            for key in attributes.keys.sorted() {
                let value = attributes[key]!
                if SVGSanitizer.isAllowedAttribute(name: key, value: value) {
                    output += " \(key)=\"\(Self.escape(value))\""
                } else {
                    removed.append("\(name)@\(key)")
                }
            }
            output += ">"
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if skipDepth > 0 { skipDepth -= 1; return }
            stack.removeLast()
            if name == "style" {
                if SVGSanitizer.isSafeCSS(styleBuffer) {
                    output += Self.escape(styleBuffer)
                } else {
                    removed.append("<style> の中身")
                }
                styleBuffer = ""
            }
            output += "</\(name)>"
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            appendText(string)
        }

        func parser(_ parser: XMLParser, foundCDATA block: Data) {
            appendText(String(decoding: block, as: UTF8.self))
        }

        private func appendText(_ text: String) {
            guard skipDepth == 0, !stack.isEmpty else { return }
            if stack.contains("style") {
                styleBuffer += text
                return
            }
            output += Self.escape(text)
        }

        static func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
        }
    }
}
