import Foundation

/// 問題に取り組み中の子どもの発話について、Jev に聞いた答え（spec §3⑥「発話の意図」「答えが正しそうか」）。
struct AnswerDecision: Sendable, Equatable {
    var intent: UtteranceIntent?
    /// 正しそうかの段階の期待値（0〜2。0 = 違っていそう、2 = 合っていそう）。答えがなければ nil
    var correctness: Double?
}

extension TeacherDecisions {
    /// 発話の意図と、答えが正しそうかを 1 回のリクエストで聞く（問題に取り組み中の発話ごとに呼ぶので、往復を 1 回にする）
    func judgeAnswer(
        problem: String, expectedAnswer: String, utterance: String, teacherLastSaid: String? = nil, timeout: Duration? = nil
    ) async -> AnswerDecision? {
        var fields = ["situation": Self.situation, "problem": problem, "correct_answer": expectedAnswer, "child_answer": utterance]
        if let teacherLastSaid { fields["teacher_last_said"] = teacherLastSaid }
        let result = await client.decide(
            state: .fields(fields),
            questions: [Key.intent: Self.intentQuestion, Key.correctness: Self.correctnessQuestion],
            timeout: timeout
        )
        guard let result else { return nil }
        let decision = AnswerDecision(
            intent: result[Key.intent]?.choiceIndex.map { UtteranceIntent.allCases[$0] },
            correctness: result[Key.correctness]?.scoreValue
        )
        return decision.intent == nil && decision.correctness == nil ? nil : decision
    }
}

extension DecisionAnswer {
    /// 段階の期待値（小数）。段階の答えでなければ nil
    var scoreValue: Double? {
        if case let .score(value, _, _, _) = self { return value }
        return nil
    }
}
