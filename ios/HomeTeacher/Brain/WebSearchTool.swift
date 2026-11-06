import Foundation

/// インターネットで調べている様子（#114）。ストリームの順に届く。
enum ResearchUpdate: Equatable, Sendable {
    /// この言葉で調べ始めた
    case searching(query: String)
    /// 調べ終わった。子どもに見せるのはサイトだけ（ページの題名は見せない）
    case found(query: String, sites: [String])
    /// 調べられなかった、何も見つからなかった
    case failed(query: String)
    /// 参考の写真を探し始めた（#116）
    case searchingImage(query: String)
    case foundImage(query: String)
    case missedImage(query: String)

    /// 調べ始めの知らせか
    var isStart: Bool {
        switch self {
        case .searching, .searchingImage: true
        default: false
        }
    }

    var isImage: Bool {
        switch self {
        case .searchingImage, .foundImage, .missedImage: true
        default: false
        }
    }

    init(results: [WebSearchTool.Result], errorCode: String?, query: String) {
        let sites = WebSearchTool.sites(from: results)
        if errorCode != nil || sites.isEmpty {
            self = .failed(query: query)
        } else {
            self = .found(query: query, sites: sites)
        }
    }
}

/// Anthropic の web_search（サーバーツール）のストリームの読み取り（定義は prompts/tools/web_search.json）。
enum WebSearchTool {
    static let name = "web_search"

    struct Result: Equatable, Sendable {
        let title: String
        let url: String
    }

    /// `web_search_tool_result` の content。成功は結果の配列、失敗は `error_code` を持つオブジェクト（どちらも HTTP 200）。
    static func parseResult(_ content: JSONValue?) -> (results: [Result], errorCode: String?) {
        switch content {
        case .array(let items)?:
            let results = items.compactMap { item -> Result? in
                guard case .object(let fields) = item, case .string(let url)? = fields["url"] else { return nil }
                if case .string(let title)? = fields["title"] { return Result(title: title, url: url) }
                return Result(title: "", url: url)
            }
            return (results, nil)
        case .object(let fields)?:
            if case .string(let code)? = fields["error_code"] { return ([], code) }
            return ([], "unknown")
        default:
            return ([], "unknown")
        }
    }

    /// 検索の入力から言葉を取り出す。
    static func query(from input: JSONValue) -> String {
        if case .object(let fields) = input, case .string(let query)? = fields["query"] {
            return query.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    /// 結果のサイト（ホスト名）を、出てきた順に重ならないように並べる。
    static func sites(from results: [Result]) -> [String] {
        var seen = Set<String>()
        var sites: [String] = []
        for result in results {
            guard let host = URL(string: result.url)?.host()?.lowercased(), seen.insert(host).inserted else { continue }
            sites.append(host)
        }
        return sites
    }
}

/// 読み上げる文の整形。マークダウンの記号は声にすると変になるので除く。
enum SpeechText {
    static func clean(_ text: String) -> String {
        text.replacing(/\*\*|__|`|^#{1,6}\s*|^[-・*]\s+/.anchorsMatchLineEndings(), with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
