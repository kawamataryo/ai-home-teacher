import Foundation

/// ヒントの段階（spec §3②、prompts/hint_ladder.md）。
enum HintStage: String, Codable, Sendable {
    // reading / thinking
    case whatIsAsked
    case whereToLook
    case approach
    case walkThrough
    // writing
    case organize
    case structure
    case review

    static func stages(for kind: ProblemKind) -> [HintStage] {
        switch kind {
        case .reading, .thinking: [.whatIsAsked, .whereToLook, .approach, .walkThrough]
        case .writing: [.organize, .structure, .review]
        }
    }

    var label: String {
        switch self {
        case .whatIsAsked: "何を聞かれているかを確認する"
        case .whereToLook: "どこを見ればよいか（注目する場所）"
        case .approach: "考え方の方向"
        case .walkThrough: "一緒に解き方をたどる"
        case .organize: "書くことを一緒に整理する"
        case .structure: "構成を考える"
        case .review: "書いたものを見て講評する"
        }
    }

    /// 段階ごとに先生が守ること。先生のメモに入れる。
    var guidance: String {
        switch self {
        case .whatIsAsked: "問題の条件を子どもの言葉で言いかえてもらう。まだ解き方には触れない。"
        case .whereToLook: "見る場所（表の行・グラフの部分・使う条件や数）を1つだけ指す。"
        case .approach: "使えそうな考え方を1つだけ示す。計算の答えは言わない。"
        case .walkThrough:
            "1手ずつ子どもに計算や判断をしてもらいながら進む。最後のひと言（答え）は必ず子どもに言わせ、「ということは？」で止める。"
        case .organize: "思いうかぶことを子どもに言ってもらい、短くまとめて返す。先生が文章を書かない。"
        case .structure: "「はじめ・なか・おわり」に何を書くかを子どもに決めてもらう。文字数や段落の条件を一緒に確認する。"
        case .review: "書けたものを撮影してもらい、よいところを具体的に1〜2つほめ、直すとよくなる点を1つだけ伝える。直し方は子どもに考えてもらう。"
        }
    }

    /// Sonnet のヒントが足りないときに使う問いかけ。
    var fallbackHint: String {
        switch self {
        case .whatIsAsked: "この問題、何を答えればいいんだっけ？最後の一文をもう一回読んでみて？"
        case .whereToLook: "問題の中で、使えそうなところはどこかな？"
        case .approach: "比べる・図にする・小さい数で試す、のどれが使えそう？"
        case .walkThrough: "一緒に1つずつやってみよう。まず最初は何をする？"
        case .organize: "この題で、思いうかぶことを3つ言ってみて？"
        case .structure: "はじめ・なか・おわりに、それぞれ何を書く？"
        case .review: "書けたら見せてね。いいところを一緒に探そう。"
        }
    }
}

/// ヒントの段階を進める出来事。
enum HintEvent: Equatable, Sendable {
    /// 「わからない」「答え教えて」「ヒント」など
    case askedForHelp
    /// 子どもが答えたが、違っていた
    case wrongAttempt
    /// 子どもがその段階でやることを終えた（作文の整理・構成ができた）
    case stageCompleted
    /// 作文を書き終えて撮影した（講評へ）
    case submittedWriting
    /// 子どもが自分で正答にたどりついた
    case solved
}

/// ヒントの段階の状態機械。一度に1段だけ進め、正答は持たない（正答は先生のメモと AnswerLeakGuard が持つ）。
///
/// - reading / thinking：何を聞かれているか → どこを見るか → 考え方 → 一緒にたどる
/// - writing：整理 → 構成 → 講評
/// - 「わからない」などの助けを求める発話で1段進む。最後の段階ではそこに留まる
/// - 違う答えは、同じ段階で `wrongAttemptsToAdvance` 回つまずいたら1段進む（hint_ladder.md の「2回つまずいたら」）
/// - 作文は、子どもがその段階を終えたとき（整理→構成）と、書いたものを撮影したとき（→講評）だけ進む
struct HintLadder: Equatable, Sendable {
    /// 同じ段階で何回違う答えを言ったら次へ進むか。
    static let defaultWrongAttemptsToAdvance = 2

    let kind: ProblemKind
    let stages: [HintStage]
    /// 段階ごとのヒント（Sonnet の hint_steps を段階の数に揃えたもの）
    let hints: [String]
    let wrongAttemptsToAdvance: Int
    /// 0 から始まる今の段階の位置。
    private(set) var index = 0
    /// 今の段階で違う答えを言った回数。
    private(set) var wrongAttempts = 0
    private(set) var isSolved = false

    init(kind: ProblemKind, hints: [String], wrongAttemptsToAdvance: Int = defaultWrongAttemptsToAdvance) {
        self.kind = kind
        self.stages = HintStage.stages(for: kind)
        self.hints = ProblemAnalysis(kind: kind, problemSummary: "", answer: "", hintSteps: hints).normalized().hintSteps
        self.wrongAttemptsToAdvance = max(1, wrongAttemptsToAdvance)
    }

    init(analysis: ProblemAnalysis, wrongAttemptsToAdvance: Int = defaultWrongAttemptsToAdvance) {
        self.init(kind: analysis.kind, hints: analysis.hintSteps, wrongAttemptsToAdvance: wrongAttemptsToAdvance)
    }

    /// 1 から始まる段階の番号（先生のメモ用）。
    var level: Int { index + 1 }
    var stage: HintStage { stages[index] }
    var currentHint: String { hints[index] }
    var isAtLastStage: Bool { index == stages.count - 1 }

    /// 出来事を受けて段階を進める。進んだら true。
    @discardableResult
    mutating func handle(_ event: HintEvent) -> Bool {
        guard !isSolved else { return false }
        switch event {
        case .askedForHelp:
            // 作文は「わからない」で先へ進めない（構成を飛ばすと先生が代わりに考えることになる）。
            // 同じ段階のまま、問いを小さくしてもらう
            guard kind != .writing else { return false }
            return advance()
        case .wrongAttempt:
            guard kind != .writing else { return false }
            wrongAttempts += 1
            guard wrongAttempts >= wrongAttemptsToAdvance else { return false }
            return advance()
        case .stageCompleted:
            // 講評は書いたものを見てから（submittedWriting）なので、構成からは進めない
            if stage == .structure { return false }
            return advance()
        case .submittedWriting:
            guard kind == .writing, let review = stages.firstIndex(of: .review), index != review else { return false }
            index = review
            wrongAttempts = 0
            return true
        case .solved:
            isSolved = true
            return false
        }
    }

    private mutating func advance() -> Bool {
        guard !isAtLastStage else { return false }
        index += 1
        wrongAttempts = 0
        return true
    }
}

/// 助けを求める発話（「わからない」「答え教えて」「ヒント」）かどうかを規則で決める。
/// 言い方で決まるものはここで先に決め（Jev を待たない）、言い方で拾えないもの（「どうやるの？」など）は Jev の help_request で拾う（AnswerJudge）。
enum HelpRequestDetector {
    static let phrases = [
        "わからない", "わかんない", "わかんね", "分からない", "分かんない", "解らない",
        "答え教えて", "こたえおしえて", "答えおしえて", "こたえ教えて", "答えを教えて", "答えは何", "答えなに",
        "ヒント", "教えて", "おしえて",
        "むずかしい", "難しい", "無理", "むり", "できない", "降参", "こうさん", "ギブ",
    ]

    static func isHelpRequest(_ utterance: String) -> Bool {
        let text = utterance.precomposedStringWithCompatibilityMapping
            .filter { !$0.isWhitespace && !$0.isPunctuation }
        return phrases.contains { text.contains($0) }
    }
}
