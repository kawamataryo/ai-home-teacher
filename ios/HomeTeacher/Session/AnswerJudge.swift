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
        /// 正答との照合（AnswerLeakGuard の表記揃え）
        case rule = "規則"
        case jev = "Jev"
        /// Jev が使えず、規則の代わりの判定
        case fallback = "規則（Jev なし）"
    }

    var verdict: AnswerVerdict
    var source: Source
}

/// 子どもの発話を答えとして判定する。テストではモックに差し替える
@MainActor
protocol AnswerJudging: AnyObject {
    func judge(_ utterance: String, tutoring: TutoringState, teacherLastSaid: String?) async -> AnswerJudgement
}

/// 規則（正答との照合）→ Jev（発話の意図 ＋ 正しそうか）→ 規則の代わりの判定、の順に決める（spec §3⑥）。
///
/// - 正答（と言いかえ）が発話に含まれていれば、Jev に聞かずに `correct`（表記の揺れは AnswerLeakGuard と同じに揃える）
/// - 「わからない」などの助けを求める発話は、答えではない（ヒントの段階は HelpRequestDetector で進める）
/// - Jev：意図が「答え」で、正しそうかが `correctThreshold` 以上なら `correct`、`wrongThreshold` 以下なら `wrong`。
///   途中の考え（「4と6」「たて×横」）は真ん中あたりの値になるので、どちらにもしない
/// - Jev が使えないとき：正答が数で、発話に数が 1 つだけあり、質問の言い方でなければ `wrong`
/// - 作文・正答がない問題・もう解けた問題では判定しない
@MainActor
final class AnswerJudge: AnswerJudging {
    /// 正しそうかがこれ以上なら正答（0〜2）
    nonisolated static let correctThreshold = 1.8
    /// これ以下なら違う答え
    nonisolated static let wrongThreshold = 0.3
    /// 返事を作る前に待つので短めにする（実測 150〜400ms）
    static let defaultTimeout: Duration = .milliseconds(500)

    nonisolated static let questionWords = ["どこ", "どう", "なに", "何", "なん", "どれ", "いくつ", "どの"]

    let decisions: TeacherDecisions?
    let timeout: Duration

    init(decisions: TeacherDecisions?, timeout: Duration = AnswerJudge.defaultTimeout) {
        self.decisions = decisions
        self.timeout = timeout
    }

    func judge(_ utterance: String, tutoring: TutoringState, teacherLastSaid: String?) async -> AnswerJudgement {
        let analysis = tutoring.analysis
        guard analysis.kind != .writing, !analysis.answer.isEmpty, !tutoring.ladder.isSolved else {
            return AnswerJudgement(verdict: .notAnAnswer, source: .rule)
        }
        if tutoring.leakGuard.containsAnswer(utterance) {
            return AnswerJudgement(verdict: .correct, source: .rule)
        }
        if HelpRequestDetector.isHelpRequest(utterance) {
            return AnswerJudgement(verdict: .notAnAnswer, source: .rule)
        }
        if let decisions, let decision = await decisions.judgeAnswer(
            problem: analysis.problemSummary, expectedAnswer: analysis.answer, utterance: utterance,
            teacherLastSaid: teacherLastSaid, timeout: timeout
        ) {
            return AnswerJudgement(verdict: Self.verdict(decision), source: .jev)
        }
        return AnswerJudgement(verdict: Self.ruleVerdict(utterance, leakGuard: tutoring.leakGuard), source: .fallback)
    }

    nonisolated static func verdict(_ decision: AnswerDecision) -> AnswerVerdict {
        guard let correctness = decision.correctness else { return .notAnAnswer }
        switch decision.intent {
        case .answer:
            if correctness >= correctThreshold { return .correct }
            if correctness <= wrongThreshold { return .wrong }
            return .notAnAnswer
        case .question:
            // 「24かな？」のように聞く形で答えることもある。違うかどうかは答えのときだけ決める
            return correctness >= correctThreshold ? .correct : .notAnAnswer
        default:
            // 雑談などの値は当てにならない（実測で 0.5〜0.9 が出る）
            return .notAnAnswer
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
    mutating func react(to utterance: String, verdict: AnswerVerdict) -> TutoringReaction {
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
            guard HelpRequestDetector.isHelpRequest(utterance) else { return .none }
            return ladder.handle(.askedForHelp) ? .advancedByHelp : .none
        }
    }
}
