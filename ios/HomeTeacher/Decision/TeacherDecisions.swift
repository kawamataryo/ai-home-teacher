import Foundation

/// 学習セッションの今の段階。「今、声をかけるべきか」の規則に使う。
enum StudyPhase: String, Sendable {
    /// 問題に取り組んでいる
    case working = "問題に取り組んでいる"
    /// 休憩中
    case onBreak = "休憩中"
    /// 先生がヒントを出したばかり
    case afterHint = "先生がヒントを出したばかり"
}

/// 「今、声をかけるべきか」を決める材料（規則で決める。数だけなので Jev には聞かない）。
struct NudgeContext: Sendable, Equatable {
    /// 手が止まっている時間（分）
    var minutesStalled: Double
    var phase: StudyPhase
    /// 先生が最後に話してからの時間（分）。わからなければ nil
    var minutesSinceTeacherSpoke: Double?
    /// 顔が画面の前にあるか
    var isFacePresent: Bool = true
}

/// 取り組み中の問題（答えの判定に使う）。答えを決められる問題のときだけ作る
struct ProblemContext: Sendable, Hashable {
    var problem: String
    var correctAnswer: String
}

/// 発話の判断に添える状況。同じ発話でも状況が違えば別に聞く
struct UtteranceContext: Sendable, Hashable {
    /// 先生が最後に話した文（返事かどうかの手がかり）
    var teacherLastSaid: String?
    var problem: ProblemContext?
}

/// 1 つの発話についての判断をまとめて聞いた結果（それぞれ「はい」の確率）。答えがなかった項目は nil。
struct UtteranceAnalysis: Sendable, Equatable {
    var addressedToTeacher: Double?
    var utteranceComplete: Double?
    var captureRequest: Double?
    var helpRequest: Double?
    /// 問題の答えを言っているか（問題に取り組み中だけ聞く）
    var givesAnswer: Double?
    /// 言った答えが正答と同じか（問題に取り組み中だけ聞く）
    var matchesAnswer: Double?
}

/// 確率の読み方（公式の目安: 0.7 以上ははい、0.3 以下はいいえ、あいだは決まらない）
enum DecisionReading: Sendable, Equatable {
    case yes, unsure, no

    init(_ probability: Double) {
        if probability >= TeacherDecisions.Threshold.yes {
            self = .yes
        } else if probability <= TeacherDecisions.Threshold.no {
            self = .no
        } else {
            self = .unsure
        }
    }
}

/// アプリが Jev に聞く判断の定義（質問文としきい値）。質問としきい値はこのファイルだけに置く。
///
/// 公式のドキュメント（https://docs.typesafe.ai/llms.txt ）と agent skill に沿って:
/// - 同じ発話への質問は 1 回のリクエストにまとめる（並列に答えるので速さはほぼ変わらない）。使うかわからない質問も先に聞き、使うかはコードで決める
/// - 「〜すべきか」の決定は聞かず、観察できる 1 つの判断だけを聞く。決定はコード（各 Jev*Judge・AnswerJudge）でする
/// - 質問文は英語にする。Jev の主な学習言語は英語で、2026-11-03 の実測でも日本語の質問より正確だった（発話は日本語のまま送る）
/// - しきい値を調整しているのでモデルは固定する（DecisionClient.defaultModel）
struct TeacherDecisions: Sendable {
    let client: DecisionClient

    enum Threshold {
        /// これ以上なら「はい」
        static let yes = 0.7
        /// これ以下なら「いいえ」
        static let no = 0.3
        /// 言い終わったとみなして無音を待たずに区切る確率。途中で区切ると子どもの話をさえぎるので、ほかより高くする
        static let complete = 0.8
    }

    /// 状況の説明。どの発話の state にも入れる
    static let situation = "A 5th-grade child in Japan is studying at home, talking out loud with an AI home tutor (\"sensei\") on an iPad. "
        + "Siblings or family may be nearby. `utterance` is a Japanese speech-recognition transcript; punctuation and typos vary."

    // MARK: - 質問の定義

    enum Key {
        static let addressed = "addressed_to_teacher"
        static let complete = "utterance_complete"
        static let capture = "capture_request"
        static let help = "help_request"
        static let givesAnswer = "gives_answer"
        static let matchesAnswer = "matches_answer"
    }

    static let addressedQuestion = DecisionQuestion.boolean(
        instructions: "Is `utterance` spoken to the AI tutor?",
        whenTrue: "A question, request, reply or call to the tutor",
        whenFalse: "Talking to oneself, reading the problem aloud, talking to a sibling or parent, or TV sound"
    )

    static let completeQuestion = DecisionQuestion.boolean(
        instructions: "Has the child finished what they wanted to say in `utterance`?",
        whenTrue: "A complete thought the tutor can reply to now",
        whenFalse: "It stops mid-sentence, like 「えっと」「あのね」 or ending in 「〜で」「〜と、」, and more is coming"
    )

    static let captureQuestion = DecisionQuestion.boolean(
        instructions: "Is the child asking the tutor to look at something on paper, such as their notebook or worksheet?",
        whenTrue: "Phrases like 「これ見て」「ここわかんない」「見てほしい」 that want the tutor to see the page",
        whenFalse: "A reply, an answer, small talk, or a question that does not need the page"
    )

    static let helpQuestion = DecisionQuestion.boolean(
        instructions: "Is the child asking for help with the current problem?",
        whenTrue: "Saying they don't get it, asking for a hint, or asking how to do it",
        whenFalse: "Giving an answer or an idea, small talk, or saying they want a break"
    )

    static let givesAnswerQuestion = DecisionQuestion.boolean(
        instructions: "Is the child stating an answer to `problem` in `utterance`?",
        whenTrue: "States a final answer, including unsure forms like 「24かな？」",
        whenFalse: "A question, asking for help, small talk, or a partial step like 「4と6」 or 「たて×横」"
    )

    static let matchesAnswerQuestion = DecisionQuestion.boolean(
        instructions: "Is the answer in `utterance` the same as `correct_answer`?",
        whenTrue: "Same answer; different notation or reading (e.g. 「にじゅうよん」 vs 24) counts as the same",
        whenFalse: "A different answer, or no answer at all"
    )

    // MARK: - 発話についての判断

    /// 発話についての判断を 1 回のリクエストでまとめて聞く。問題に取り組み中なら答えの判定も一緒に聞く
    func analyzeUtterance(_ utterance: String, context: UtteranceContext, timeout: Duration? = nil) async -> UtteranceAnalysis? {
        var questions = [
            Key.addressed: Self.addressedQuestion,
            Key.complete: Self.completeQuestion,
            Key.capture: Self.captureQuestion,
            Key.help: Self.helpQuestion,
        ]
        if context.problem != nil {
            questions[Key.givesAnswer] = Self.givesAnswerQuestion
            questions[Key.matchesAnswer] = Self.matchesAnswerQuestion
        }
        let result = await client.decide(state: Self.utteranceState(utterance, context: context), questions: questions, timeout: timeout)
        guard let result else { return nil }
        return UtteranceAnalysis(
            addressedToTeacher: result[Key.addressed]?.probability,
            utteranceComplete: result[Key.complete]?.probability,
            captureRequest: result[Key.capture]?.probability,
            helpRequest: result[Key.help]?.probability,
            givesAnswer: result[Key.givesAnswer]?.probability,
            matchesAnswer: result[Key.matchesAnswer]?.probability
        )
    }

    static func utteranceState(_ utterance: String, context: UtteranceContext) -> DecisionState {
        var fields = ["situation": situation, "utterance": utterance]
        if let teacherLastSaid = context.teacherLastSaid { fields["teacher_last_said"] = teacherLastSaid }
        if let problem = context.problem {
            fields["problem"] = problem.problem
            fields["correct_answer"] = problem.correctAnswer
        }
        return .fields(fields)
    }
}
