import Foundation

/// 問題に取り組み中の子どもの発話が、答えとして合っているか（#73）。
enum AnswerVerdict: String, Equatable, Sendable {
    /// 正答を言えた
    case correct
    /// 答えを言ったが違っていた
    case wrong
    /// 答えではない（質問・助けを求める・雑談・途中の考えなど）か、決められない
    case notAnAnswer
}

/// 判定の結果と、どこで決めたか（記録用）
struct AnswerJudgement: Equatable, Sendable {
    enum Source: String, Sendable {
        /// 正答との照合（AnswerLeakGuard の表記揃え）や、助けを求める言い方
        case rule = "規則"
        case jev = "Jev"
        /// Jev が使えず、規則の代わりの判定
        case fallback = "規則（Jev なし）"
    }

    var verdict: AnswerVerdict
    var source: Source
    /// 助けを求める発話か（ヒントの段階を 1 つ進める）
    var asksForHelp = false
}

/// 子どもの発話を答えとして判定する。テストではモックに差し替える
@MainActor
protocol AnswerJudging: AnyObject {
    func judge(_ utterance: String, tutoring: TutoringState) async -> AnswerJudgement
}

/// 規則（正答との照合・助けを求める言い方）→ Jev（答えを言っているか ＋ 正答と同じか ＋ 助けを求めているか）→ 規則の代わりの判定、の順に決める（spec §3②）。
///
/// - 正答（と言いかえ）が発話に含まれていれば、Jev を待たずに `correct`（表記の揺れは AnswerLeakGuard と同じに揃える）
/// - 「わからない」などの助けを求める言い方は、答えではない。Jev が「助けを求めている」と答えたときも同じ（「どうやるの？」など）
/// - Jev：答えを言っていて（はい）、正答と同じなら（はい）`correct`、違えば（いいえ）`wrong`。どちらかが迷う帯ならどちらにもしない。
///   途中の考え（「4と6」「たて×横」）は「答えを言っていない」になる
/// - Jev が使えないとき：正答が数で、発話に数が 1 つだけあり、質問の言い方でなければ `wrong`
/// - 作文・正答がない問題・もう解けた問題では判定しない
///
/// Jev の判断は発話の判断と同じリクエストで先に聞いてある（UtteranceDecisionCache）ので、ふつうは待たない
@MainActor
final class AnswerJudge: AnswerJudging {
    /// 返事を作る前に待つので短めにする（先読みが間に合わなかったときだけ待つ）
    static let defaultTimeout: Duration = .milliseconds(500)

    nonisolated static let questionWords = ["どこ", "どう", "なに", "何", "なん", "どれ", "いくつ", "どの"]

    let cache: UtteranceDecisionCache?
    let timeout: Duration

    init(cache: UtteranceDecisionCache?, timeout: Duration = AnswerJudge.defaultTimeout) {
        self.cache = cache
        self.timeout = timeout
    }

    func judge(_ utterance: String, tutoring: TutoringState) async -> AnswerJudgement {
        let ruleHelp = HelpRequestDetector.isHelpRequest(utterance)
        guard let problem = Self.problemContext(tutoring) else {
            return AnswerJudgement(verdict: .notAnAnswer, source: .rule, asksForHelp: ruleHelp)
        }
        if tutoring.leakGuard.containsAnswer(utterance) {
            return AnswerJudgement(verdict: .correct, source: .rule)
        }
        if ruleHelp {
            return AnswerJudgement(verdict: .notAnAnswer, source: .rule, asksForHelp: true)
        }
        if let cache {
            // ふつうは StudySessionCoordinator が揃えている。揃っていないと先読みとは別に聞き直す
            cache.problem = problem
            if let analysis = await cache.analysis(for: utterance, within: timeout) {
                if let help = analysis.helpRequest, DecisionReading(help) == .yes {
                    return AnswerJudgement(verdict: .notAnAnswer, source: .jev, asksForHelp: true)
                }
                if let verdict = Self.verdict(analysis) {
                    return AnswerJudgement(verdict: verdict, source: .jev)
                }
            }
        }
        return AnswerJudgement(verdict: Self.ruleVerdict(utterance, leakGuard: tutoring.leakGuard), source: .fallback)
    }

    /// 答えを判定する問題か。作文・正答がない問題・もう解けた問題では nil
    nonisolated static func problemContext(_ tutoring: TutoringState) -> ProblemContext? {
        let analysis = tutoring.analysis
        guard analysis.kind != .writing, !analysis.answer.isEmpty, !tutoring.ladder.isSolved else { return nil }
        return ProblemContext(problem: analysis.problemSummary, correctAnswer: analysis.answer)
    }

    /// Jev の答えから判定する。答えの判定が返ってこなければ nil（規則の代わりの判定に任せる）
    nonisolated static func verdict(_ analysis: UtteranceAnalysis) -> AnswerVerdict? {
        guard let givesAnswer = analysis.givesAnswer, let matchesAnswer = analysis.matchesAnswer else { return nil }
        guard DecisionReading(givesAnswer) == .yes else { return .notAnAnswer }
        switch DecisionReading(matchesAnswer) {
        case .yes: return .correct
        case .no: return .wrong
        case .unsure: return .notAnAnswer
        }
    }

    /// Jev が使えないときの、違う答えの見分け方。正答の照合はすでに済んでいる
    nonisolated static func ruleVerdict(_ utterance: String, leakGuard: AnswerLeakGuard) -> AnswerVerdict {
        guard leakGuard.hasNumericAnswer else { return .notAnAnswer }
        let quantities = AnswerLeakGuard.Normalized(utterance).quantities
        guard Set(quantities.map(\.value)).count == 1 else { return .notAnAnswer }
        let text = AnswerNormalizer.text(utterance)
        guard !questionWords.contains(where: text.contains) else { return .notAnAnswer }
        return .wrong
    }
}

/// 判定を受けて、ヒントの段階がどう変わったか
enum TutoringReaction: Equatable, Sendable {
    /// 変わらない（答えではなかった）
    case none
    /// 助けを求められて 1 段進めた
    case advancedByHelp
    /// 違う答え。`advanced` なら 2 回目で次の段階に進めた（励ます）
    case wrongAttempt(advanced: Bool)
    /// 自分で解けた（ほめる）
    case solved

    /// 返事の頭に添える定型句と、そのときの表情。なければ nil（表情は返事のしるしで決める）
    var cue: ReplyCue? {
        switch self {
        case .solved: ReplyCue(lead: ReplyCue.praisePhrase, emotion: .praise)
        case .wrongAttempt(advanced: true): ReplyCue(lead: nil, emotion: .encourage)
        case .none, .advancedByHelp, .wrongAttempt(advanced: false): nil
        }
    }
}

/// 返事の表情を決めておくもの。`lead` は Haiku の 1 文目を待たずに話す定型句（同梱の音声ですぐ鳴る）
struct ReplyCue: Equatable, Sendable {
    /// 定型句「すごいじゃん！」（teacher_phrases.json の sugoi_jan）
    static let praisePhrase = "すごいじゃん！"

    var lead: String?
    var emotion: AvatarEmotion
}

extension TutoringState {
    /// 子どもの発話の判定でヒントの段階を進める（解けた・違う答え・助けを求めた）
    @discardableResult
    /// `asksForHelp` を省くと、助けを求める発話かは言い方（HelpRequestDetector）で決める
    mutating func react(to utterance: String, verdict: AnswerVerdict, asksForHelp: Bool? = nil) -> TutoringReaction {
        guard !ladder.isSolved else { return .none }
        switch verdict {
        case .correct:
            // Jev だけが正答とみなしたとき（「にじゅうよん」など）も、そのあとは先生が答えを繰り返してよい
            leakGuard.markRevealedByChild()
            ladder.handle(.solved)
            return .solved
        case .wrong:
            return .wrongAttempt(advanced: ladder.handle(.wrongAttempt))
        case .notAnAnswer:
            guard asksForHelp ?? HelpRequestDetector.isHelpRequest(utterance) else { return .none }
            return ladder.handle(.askedForHelp) ? .advancedByHelp : .none
        }
    }
}
