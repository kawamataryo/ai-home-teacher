import Foundation

/// 先生の発話を読み上げる前に正答と照合し、答えを先に言ってしまう文を止める（spec §3②「答えを言わないルール」）。
///
/// Haiku はプロンプトで答えを言わないよう指示されているが、確率的に破ることがあるので、TTS の手前でもう一度検査する。
///
/// - 数：全角・半角、桁区切り（1,200）、漢数字（二十四）、分数（4分の3 = 3/4 = 0.75）、％（75% = 0.75）を揃えて比べる。
///   数の境目を見るので、答えが 4 のとき 24・40・0.4 は止めない
/// - 単位：センチ / cm、平方センチメートル / cm² / ㎠ などを揃える。答えに単位があるとき、別の単位が付いた同じ数（4個 に対する 4人）は止めない
/// - 言葉：答えが言葉（東京・三角形など）なら、表記を揃えて含まれるかを見る。1文字の記号（ア・イ）は、前後が同じ種類の文字でないときだけ止める（「イメージ」は止めない）
/// - 子どもが先に正答を言ったら（`noteChildUtterance`）、そのあとは先生が繰り返してよい（「そう、24cm²だね」）
///
/// 作文（正答がない）では何も止めない。
struct AnswerLeakGuard: Equatable, Sendable {
    enum Verdict: Equatable, Sendable {
        case allowed
        /// 止めた。かわりに `replacement` を読み上げる
        case blocked(replacement: String)
    }

    static let defaultReplacement = "おっと、ここから先は、きみに言ってほしいな。どうなると思う？"

    private let patterns: [Pattern]
    let replacement: String
    /// 子どもが先に正答を言った。
    private(set) var isRevealedByChild = false

    init(answer: String, variants: [String] = [], replacement: String = defaultReplacement) {
        self.patterns = ([answer] + variants).compactMap(Pattern.init)
        self.replacement = replacement
    }

    init(analysis: ProblemAnalysis, replacement: String = defaultReplacement) {
        if analysis.kind == .writing {
            self.init(answer: "", replacement: replacement)
        } else {
            self.init(answer: analysis.answer, variants: analysis.answerVariants, replacement: replacement)
        }
    }

    /// 検査する正答があるか（作文や、答えが読めなかったときは false）。
    var isActive: Bool { !patterns.isEmpty && !isRevealedByChild }

    /// 先生の文に正答が含まれているか。
    func containsAnswer(_ sentence: String) -> Bool {
        let text = Normalized(sentence)
        return patterns.contains { $0.matches(text) }
    }

    func check(_ sentence: String) -> Verdict {
        guard isActive, containsAnswer(sentence) else { return .allowed }
        return .blocked(replacement: replacement)
    }

    /// 読み上げてよい文を返す（止めたときはかわりの文）。
    func screen(_ sentence: String) -> String {
        switch check(sentence) {
        case .allowed: sentence
        case .blocked(let replacement): replacement
        }
    }

    /// 子どもの発話を見て、正答を言っていたら以降は止めない。言っていたら true。
    @discardableResult
    mutating func noteChildUtterance(_ utterance: String) -> Bool {
        guard !patterns.isEmpty, containsAnswer(utterance) else { return false }
        isRevealedByChild = true
        return true
    }

    /// 子どもが正答を言ったと別の判定（Jev など）で決めたとき。以降は先生が答えを繰り返してよい
    mutating func markRevealedByChild() {
        isRevealedByChild = true
    }

    /// 正答が数か（数の答えなら、数を言った発話は答えようとしたものとみなせる）
    var hasNumericAnswer: Bool {
        patterns.contains { if case .numbers = $0 { true } else { false } }
    }
}

// MARK: - 照合の中身

extension AnswerLeakGuard {
    /// 数と単位。
    struct Quantity: Equatable, Sendable {
        var value: Double
        var unit: String?

        func matches(_ other: Quantity) -> Bool {
            guard abs(value - other.value) < 1e-9 else { return false }
            // どちらかに単位がなければ同じ数とみなす。両方にあって違えば別のもの（4個 と 4人）
            guard let unit, let otherUnit = other.unit else { return true }
            return unit == otherUnit
        }

        /// ％は割合の小数とも比べる（75% = 0.75）。
        var equivalents: [AnswerLeakGuard.Quantity] {
            unit == "%" ? [self, Quantity(value: value / 100, unit: nil)] : [self]
        }
    }

    /// 正答の1つの書き方。
    enum Pattern: Equatable, Sendable {
        /// 数（単位つき）。答えに数が複数あるとき（3時間20分）は全部が出たら止める
        case numbers([AnswerLeakGuard.Quantity])
        /// 2文字以上の言葉
        case text(String)
        /// 1文字の記号（ア・イ・A など）
        case symbol(Character)

        init?(_ answer: String) {
            let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let numeric = AnswerNormalizer.numeric(trimmed, protectWords: false)
            let scan = AnswerNormalizer.scanQuantities(numeric)
            if !scan.quantities.isEmpty, AnswerNormalizer.isNumericRemainder(scan.remainder) {
                self = .numbers(scan.quantities)
                return
            }
            let text = AnswerNormalizer.text(trimmed)
            guard let first = text.first else { return nil }
            self = text.count == 1 ? .symbol(first) : .text(text)
        }

        func matches(_ sentence: Normalized) -> Bool {
            switch self {
            case .numbers(let answer):
                return answer.allSatisfy { a in
                    sentence.quantities.contains { s in
                        a.equivalents.contains { ae in s.equivalents.contains { ae.matches($0) } }
                    }
                }
            case .text(let word):
                return sentence.text.contains(word)
            case .symbol(let symbol):
                let chars = Array(sentence.text)
                let kind = AnswerNormalizer.scriptKind(symbol)
                for (i, c) in chars.enumerated() where c == symbol {
                    let before = i > 0 ? AnswerNormalizer.scriptKind(chars[i - 1]) : nil
                    let after = i + 1 < chars.count ? AnswerNormalizer.scriptKind(chars[i + 1]) : nil
                    if before != kind, after != kind { return true }
                }
                return false
            }
        }
    }

    /// 検査する文を、数と言葉の両方の形にしておく。
    struct Normalized {
        let quantities: [AnswerLeakGuard.Quantity]
        let text: String

        init(_ sentence: String) {
            quantities = AnswerNormalizer.scanQuantities(AnswerNormalizer.numeric(sentence, protectWords: true)).quantities
            text = AnswerNormalizer.text(sentence)
        }
    }
}

/// 表記の揺れを揃える。
enum AnswerNormalizer {
    /// 言葉の照合用：全角・半角を揃え、小文字にし、空白と句読点・記号を消す。
    static func text(_ s: String) -> String {
        String(s.precomposedStringWithCompatibilityMapping.lowercased().filter {
            !$0.isWhitespace && !$0.isPunctuation && !"「」『』（）()".contains($0)
        })
    }

    /// 漢数字を含むが数ではない言葉。数に直す前に消す（文の検査だけ。答えの側では消さない）。
    static let nonNumericKanjiWords = [
        "一緒", "一番", "一度", "一応", "一気", "一部", "一旦", "一生", "一体", "一般", "一致", "一言", "一休み",
        "統一", "同一", "唯一", "万一", "一つずつ", "一つ一つ", "一人ひとり", "一つ目",
        "十分", "九九", "三角", "四角", "五角", "六角", "八角",
    ]

    /// 数に直したあとで消す、数を含むが答えではない言い方。
    nonisolated(unsafe) static let protectedPatterns: [NSRegularExpression] = [
        #"\d+年生"#, #"\d+角形"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    /// 単位の言いかえ（長いものから順に置きかえる）。NFKC のあとなので ㎠ → cm2、cm² → cm2 になっている。
    static let unitSynonyms: [(String, String)] = [
        ("平方センチメートル", "平方cm"), ("平方センチ", "平方cm"), ("平方メートル", "平方m"), ("平方キロメートル", "平方km"),
        ("立方センチメートル", "立方cm"), ("立方センチ", "立方cm"), ("立方メートル", "立方m"),
        ("km2", "平方km"), ("cm2", "平方cm"), ("mm2", "平方mm"), ("m2", "平方m"),
        ("cm3", "立方cm"), ("m3", "立方m"),
        ("センチメートル", "cm"), ("ミリメートル", "mm"), ("キロメートル", "km"), ("メートル", "m"), ("センチ", "cm"),
        ("キログラム", "kg"), ("グラム", "g"),
        ("ミリリットル", "ml"), ("デシリットル", "dl"), ("リットル", "l"),
        ("パーセント", "%"),
    ]

    /// 数のすぐあとに付く単位（長いものから順に見る）。
    static let units: [String] = [
        "平方cm", "平方mm", "平方km", "平方m", "立方cm", "立方m",
        "km", "cm", "mm", "kg", "ml", "dl", "m", "g", "l", "%",
        "時間", "番目", "ページ", "個", "人", "本", "枚", "円", "度", "倍", "回", "日", "分", "秒", "年", "月", "点", "割", "台", "匹", "冊",
    ]

    /// 数として読んでよい残り（約・およそ・答えの前置きなど）。
    static let ignorableWords = ["約", "およそ", "答えは", "答え", "こたえ", "です", "だよ", "だね", "くらい", "ぐらい"]

    /// 数の照合用：全角・半角、単位の言いかえ、漢数字、桁区切り、「a分のb」を揃える。
    static func numeric(_ s: String, protectWords: Bool) -> String {
        var t = s.precomposedStringWithCompatibilityMapping.lowercased()
        t = String(t.filter { !$0.isWhitespace })
        for (from, to) in unitSynonyms {
            t = t.replacingOccurrences(of: from, with: to)
        }
        if protectWords {
            for word in nonNumericKanjiWords {
                t = t.replacingOccurrences(of: word, with: "〓")
            }
        }
        t = convertKanjiNumerals(t)
        // 1,200 → 1200（3桁ごとの区切りだけ）
        t = replace(t, #"(?<=\d),(?=\d{3}(?!\d))"#, with: "")
        // 4分の3 → 3/4
        t = replace(t, #"(\d+(?:\.\d+)?)分の(\d+(?:\.\d+)?)"#, with: "$2/$1")
        if protectWords {
            for regex in protectedPatterns {
                t = regex.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "〓")
            }
        }
        return t
    }

    nonisolated(unsafe) private static let quantityRegex = try! NSRegularExpression(
        // 小数点の前後だけを数の続きとみなす（「…24」は NFKC で「...24」になるので、点だけでは区切らない）
        pattern: #"(?<!\d|\d\.)(\d+(?:\.\d+)?)(?:/(\d+(?:\.\d+)?))?(?!\d|\.\d|/\d)"#
    )

    /// 数（と直後の単位）を拾い出す。`remainder` は数と単位を取り除いた残り。
    static func scanQuantities(_ s: String) -> (quantities: [AnswerLeakGuard.Quantity], remainder: String) {
        let ns = s as NSString
        var quantities: [AnswerLeakGuard.Quantity] = []
        var remainder = ""
        var cursor = 0
        for match in quantityRegex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            remainder += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            guard let numerator = Double(ns.substring(with: match.range(at: 1))) else { continue }
            var value = numerator
            if match.range(at: 2).location != NSNotFound,
               let denominator = Double(ns.substring(with: match.range(at: 2))), denominator != 0 {
                value = numerator / denominator
            }
            var end = match.range.location + match.range.length
            let rest = ns.substring(from: end)
            let unit = units.first { rest.hasPrefix($0) }
            if let unit { end += (unit as NSString).length }
            quantities.append(AnswerLeakGuard.Quantity(value: value, unit: unit))
            cursor = end
        }
        remainder += ns.substring(from: min(cursor, ns.length))
        return (quantities, remainder)
    }

    /// 数と単位を除いた残りが、前置きや句読点だけか（＝答えが数の答えか）。
    static func isNumericRemainder(_ remainder: String) -> Bool {
        var rest = text(remainder)
        for word in ignorableWords {
            rest = rest.replacingOccurrences(of: word, with: "")
        }
        return rest.isEmpty
    }

    // MARK: 漢数字

    private static let kanjiDigits: [Character: Int] = [
        "〇": 0, "零": 0, "一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9,
    ]
    private static let kanjiMultipliers: [Character: Int] = ["十": 10, "百": 100, "千": 1000]

    private static func isKanjiNumeral(_ c: Character) -> Bool {
        kanjiDigits[c] != nil || kanjiMultipliers[c] != nil || c == "万"
    }

    /// 漢数字の並びを算用数字に直す（二十四 → 24、三百五 → 305、二〇二六 → 2026）。
    static func convertKanjiNumerals(_ s: String) -> String {
        var out = ""
        var run = ""
        func flush() {
            if !run.isEmpty { out += kanjiValue(run).map(String.init) ?? run }
            run = ""
        }
        for c in s {
            if isKanjiNumeral(c) { run.append(c) } else { flush(); out.append(c) }
        }
        flush()
        return out
    }

    static func kanjiValue(_ run: String) -> Int? {
        // 位取りなし（二〇二六）は数字を並べる
        if run.allSatisfy({ kanjiDigits[$0] != nil }) {
            return Int(run.map { String(kanjiDigits[$0]!) }.joined())
        }
        var total = 0
        var section = 0
        var current: Int?
        for c in run {
            if let d = kanjiDigits[c] {
                current = (current ?? 0) * 10 + d
            } else if let m = kanjiMultipliers[c] {
                section += (current ?? 1) * m
                current = nil
            } else if c == "万" {
                let part = section + (current ?? 0)
                total += (part == 0 ? 1 : part) * 10000
                section = 0
                current = nil
            }
        }
        return total + section + (current ?? 0)
    }

    // MARK: 文字の種類

    enum ScriptKind: Equatable {
        case hiragana, katakana, kanji, latin, digit
    }

    static func scriptKind(_ c: Character) -> ScriptKind? {
        guard let scalar = c.unicodeScalars.first else { return nil }
        switch scalar.value {
        case 0x3041...0x309F: return .hiragana
        case 0x30A0...0x30FF, 0x31F0...0x31FF: return .katakana
        case 0x4E00...0x9FFF, 0x3400...0x4DBF: return .kanji
        case 0x30...0x39: return .digit
        case 0x41...0x5A, 0x61...0x7A: return .latin
        default: return nil
        }
    }

    private static func replace(_ s: String, _ pattern: String, with template: String) -> String {
        s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }
}
