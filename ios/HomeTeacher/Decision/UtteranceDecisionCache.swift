import Foundation

/// 発話ごとの Jev の判断を 1 回のリクエストにまとめ、先に投げて覚えておく（公式の speculative fan-out）。
///
/// 無音になった時点で「言い終わったか」を聞くついでに、先生への発話か・撮影の依頼か・助けを求めているか・
/// 答えの判定もまとめて聞いておく。発話が確定したときには答えが届いている（か、届く途中な）ので、
/// 先生が話し始めるまでに Jev を待つ往復がなくなる。
///
/// 同じ書き起こし（空白と句読点を除いて同じ）と同じ状況なら、同じリクエストの答えを使う。
@MainActor
final class UtteranceDecisionCache {
    let decisions: TeacherDecisions
    /// リクエスト全体のタイムアウト。待つ側はそれぞれもっと短く待ってよい
    let timeout: Duration

    /// 先生が最後に話した文。発話の判断の state に入れる
    var teacherLastSaid: String?
    /// 取り組み中の問題。あれば答えの判定も一緒に聞く
    var problem: ProblemContext?

    private struct Key: Hashable {
        let text: String
        let context: UtteranceContext
    }

    private var entries: [(key: Key, task: Task<UtteranceAnalysis?, Never>)] = []
    /// 覚えておく発話の数（書き起こしが伸びるたびに 1 つ増えるので、少し多めに持つ）
    static let capacity = 8

    /// 実際に送ったリクエストの数（テストと記録用）
    private(set) var requestCount = 0

    init(decisions: TeacherDecisions, timeout: Duration = DecisionClient.defaultTimeout) {
        self.decisions = decisions
        self.timeout = timeout
    }

    var context: UtteranceContext {
        UtteranceContext(teacherLastSaid: teacherLastSaid, problem: problem)
    }

    /// 発話の判断。まだ聞いていなければ聞き始める
    func analysis(for utterance: String) -> Task<UtteranceAnalysis?, Never> {
        let text = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = Key(text: DecisionText.normalize(text), context: context)
        if let entry = entries.first(where: { $0.key == key }) { return entry.task }
        let decisions = self.decisions
        let context = key.context
        let timeout = self.timeout
        let task = Task { await decisions.analyzeUtterance(text, context: context, timeout: timeout) }
        requestCount += 1
        entries.append((key, task))
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
        return task
    }

    /// 発話の判断を `limit` まで待つ。間に合わなければ nil（リクエストは止めずに続け、あとで使えるようにする）
    func analysis(for utterance: String, within limit: Duration) async -> UtteranceAnalysis? {
        let task = analysis(for: utterance)
        return (try? await DecisionClient.withTimeout(limit) { await task.value }) ?? nil
    }
}
