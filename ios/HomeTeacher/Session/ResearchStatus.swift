import Foundation

/// 調べているサイト（#115）。子どもに見せるのはサイトの名前と favicon だけで、ページの題名は見せない。
struct ResearchSite: Equatable, Sendable, Identifiable {
    let host: String

    var id: String { host }

    /// 子どもが読める名前。知らないサイトはホスト名のまま出す
    var name: String {
        Self.names[host] ?? (host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)
    }

    var faviconURL: URL? {
        var components = URLComponents(string: "https://www.google.com/s2/favicons")
        components?.queryItems = [URLQueryItem(name: "domain", value: host), URLQueryItem(name: "sz", value: "64")]
        return components?.url
    }

    /// favicon が取れないときに出す 1 文字
    var initial: String { String(name.prefix(1)).uppercased() }

    private static let names: [String: String] = [
        "ja.wikipedia.org": "ウィキペディア",
        "kotobank.jp": "コトバンク",
        "kids.gakken.co.jp": "学研キッズネット",
        "benesse.jp": "ベネッセ",
        "www.kyoiku-shuppan.co.jp": "教育出版",
        "www3.nhk.or.jp": "NHK",
        "www2.nhk.or.jp": "NHK",
        "news.yahoo.co.jp": "Yahoo!ニュース",
        "kids.yahoo.co.jp": "Yahoo!きっず",
        "sports.yahoo.co.jp": "スポーツナビ",
        "www.nikkei.com": "日本経済新聞",
        "www.jiji.com": "時事通信",
        "www.tokyo-np.co.jp": "東京新聞",
        "tenki.jp": "tenki.jp",
        "weathernews.jp": "ウェザーニュース",
        "www.jma.go.jp": "気象庁",
        "www.bousai.go.jp": "内閣府 防災",
        "www.mext.go.jp": "文部科学省",
        "www.kantei.go.jp": "首相官邸",
        "www.env.go.jp": "環境省",
        "www.maff.go.jp": "農林水産省",
        "www.nao.ac.jp": "国立天文台",
        "www.jaxa.jp": "JAXA",
        "www.kahaku.go.jp": "国立科学博物館",
        "www.nasa.gov": "NASA",
        "sorae.info": "sorae",
        "natgeo.nikkeibp.co.jp": "ナショナル ジオグラフィック",
        "nazology.kusuguru.co.jp": "ナゾロジー",
        "www.britannica.com": "ブリタニカ",
        "www.nintendo.co.jp": "任天堂",
        "www.nintendo.com": "任天堂",
        "www.pokemon.co.jp": "ポケモン公式",
        "www.jleague.jp": "Jリーグ",
        "npb.jp": "日本野球機構",
        "www.jfa.jp": "日本サッカー協会",
        "www.joc.or.jp": "日本オリンピック委員会",
    ]
}

/// 調べものカードに出す様子（#115）。声の会話で黙って待たせないように、今なにをしているかを見せる。
struct ResearchStatus: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        /// 調べている
        case searching
        /// 時間がかかっている
        case slow
        /// 見つかって、読んでいる
        case found
        /// 答えを話し始めた（小さくして、調べたサイトだけ残す）
        case answered
        /// 調べられなかった
        case failed
    }

    private(set) var phase: Phase = .searching
    /// 写真を探しているか（インターネットで調べているのではなく）
    private(set) var isImage = false
    private(set) var query: String
    private(set) var sites: [ResearchSite] = []

    init(query: String) {
        self.query = query
    }

    /// カードを小さくしているか
    var isCompact: Bool { phase == .answered }

    /// 動いている途中か（探しているしるしを動かす）
    var isWorking: Bool { phase == .searching || phase == .slow }

    var headline: String {
        if isImage {
            switch phase {
            case .searching: return "写真をさがしているよ"
            case .slow: return "もうちょっとで見つかりそう"
            case .found: return "いい写真が見つかったよ！"
            case .answered: return "\(sites.prefix(2).map(\.name).joined(separator: "・"))で見つけたよ"
            case .failed: return "ぴったりの写真がなかったよ"
            }
        }
        return switch phase {
        case .searching: "インターネットで調べているよ"
        case .slow: "もうちょっとで見つかりそう"
        case .found: "見つけたよ！読んでいるところ"
        case .answered: "\(sites.prefix(2).map(\.name).joined(separator: "・"))で調べたよ"
        case .failed: "うまく調べられなかったよ"
        }
    }

    mutating func apply(_ update: ResearchUpdate) {
        switch update {
        case .searchingImage(let query):
            self.query = query
            isImage = true
            sites = [ResearchSite(host: ReferenceImageTool.site)]
            phase = .searching
        case .foundImage(let query):
            self.query = query
            phase = .found
        case .missedImage(let query):
            self.query = query
            phase = .failed
        case .searching(let query):
            self.query = query
            isImage = false
            phase = .searching
        case .found(let query, let hosts):
            self.query = query
            // 2 回調べたら、前のサイトも残す
            for host in hosts where !sites.contains(where: { $0.host == host }) {
                sites.append(ResearchSite(host: host))
            }
            phase = .found
        case .failed(let query):
            self.query = query
            // 先に見つかったものがあれば、それで答える
            phase = sites.isEmpty ? .failed : .found
        }
    }

    mutating func markSlow() {
        if phase == .searching { phase = .slow }
    }

    /// 答えを話し始めて少し経ったら小さくする。何も見つからなかったら、その言葉のまま残す
    mutating func collapse() {
        if !sites.isEmpty, phase != .failed { phase = .answered }
    }
}

/// 調べたあとの、中身のない前置き。カードで見せているので声には出さない
enum ResearchPreface {
    private static let lines: Set<String> = [
        "調べたよ", "調べたよ！", "調べたよ。", "調べてみたよ", "調べてみたよ。", "調べてみたよ！",
        "わかったよ", "わかったよ。", "わかったよ！", "わかったことを話すね", "わかったことを話すね。",
        "見つけたよ", "見つけたよ。", "見つけたよ！",
    ]

    static func matches(_ sentence: String) -> Bool {
        let text = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        return lines.contains(text) || isModelNote(text)
    }

    /// 調べたあとに、モデルが英語の注記（Note: I can't ...）を混ぜることがある。読み上げない
    /// （2026-11-06 に実際の Haiku で確かめた）。TikTok のような短い英単語を含む日本語の文は残す
    static func isModelNote(_ text: String) -> Bool {
        if text.lowercased().hasPrefix("note") { return true }
        let letters = text.unicodeScalars.filter { $0.properties.isAlphabetic }
        guard letters.count >= 12 else { return false }
        let latin = letters.filter { $0.isASCII }.count
        return latin * 10 >= letters.count * 7
    }
}
