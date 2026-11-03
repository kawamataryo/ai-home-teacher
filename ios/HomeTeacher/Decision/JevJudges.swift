import Foundation

// Jev を使う判定と、Jev が失敗・タイムアウトしたときの規則ベースの判定。
// Jev の答えが nil（通信の失敗・タイムアウト・答えが読めない）なら、必ず規則ベースに切り替える。

// MARK: - 先生への発話か

/// 先生への発話かを Jev で判断する。
/// 呼びかけ語で始まる発話は Jev に聞かずに受け付ける（はっきり呼ばれたら必ず応える。通信も減る）
@MainActor
final class JevAddressingJudge: AddressingJudge {
    let decisions: TeacherDecisions
    let fallback: CallWordAddressingJudge
    /// これ以上の確率なら先生への発話とみなす
    let threshold: Double
    let timeout: Duration
    /// 先生が最後に話した文。あれば state に入れる（返事かどうかの手がかり）
    var teacherLastSaid: String?

    init(
        decisions: TeacherDecisions,
        fallback: CallWordAddressingJudge = CallWordAddressingJudge(),
        threshold: Double = 0.5,
        timeout: Duration = DecisionClient.defaultTimeout
    ) {
        self.decisions = decisions
        self.fallback = fallback
        self.threshold = threshold
        self.timeout = timeout
    }

    func isAddressedToTeacher(_ utterance: String) async -> Bool {
        if await fallback.isAddressedToTeacher(utterance) { return true }
        guard let p = await decisions.addressedProbability(utterance, teacherLastSaid: teacherLastSaid, timeout: timeout) else {
            // Jev が使えなければ呼びかけ語だけで決める（ここに来た時点で呼びかけ語はない）
            return false
        }
        return p >= threshold
    }
}

// MARK: - 言い終わったか

/// 言い終わったかを Jev で判断する。
/// 途中で区切ると子どもの話をさえぎってしまうので、確率が高いときだけ true にする。
/// Jev が使えなければ false を返し、ConversationController の無音のタイムアウトに任せる
@MainActor
final class JevEndOfUtteranceDecider: EndOfUtteranceDecider {
    let decisions: TeacherDecisions
    let threshold: Double
    /// 無音のタイムアウト（初期値 700ms）より遅い答えは使われないので、短めにする
    let timeout: Duration

    init(decisions: TeacherDecisions, threshold: Double = 0.8, timeout: Duration = .milliseconds(400)) {
        self.decisions = decisions
        self.threshold = threshold
        self.timeout = timeout
    }

    func isUtteranceComplete(_ transcript: String) async -> Bool {
        guard let p = await decisions.completeProbability(transcript, timeout: timeout) else { return false }
        return p >= threshold
    }
}

// MARK: - 撮影の依頼か

/// 発話が撮影の依頼（ノートや問題を見てほしい）かを決める。
@MainActor
protocol CaptureRequestJudge: AnyObject {
    func isCaptureRequest(_ utterance: String) async -> Bool
}

/// 「見て」「わかんない」「見てほしい」などの言い方で撮影の依頼とみなす（Jev が使えないとき用）。
@MainActor
final class CaptureRequestDetector: CaptureRequestJudge {
    nonisolated static let defaultPatterns = [
        "見て", "みて", "見せ", "みせ", "見てほしい", "みてほしい",
        "わかんない", "わからない", "分かんない", "分からない", "わかんねー",
    ]

    let patterns: [String]

    init(patterns: [String] = CaptureRequestDetector.defaultPatterns) {
        self.patterns = patterns
    }

    func isCaptureRequest(_ utterance: String) async -> Bool {
        Self.matches(utterance, patterns: patterns)
    }

    /// 空白と句読点を無視して、どこかにパターンが含まれるか
    nonisolated static func matches(_ utterance: String, patterns: [String] = defaultPatterns) -> Bool {
        let text = DecisionText.normalize(utterance)
        return patterns.contains { !$0.isEmpty && text.contains(DecisionText.normalize($0)) }
    }
}

/// 撮影の依頼かを Jev で判断し、使えなければ `CaptureRequestDetector` で決める。
@MainActor
final class JevCaptureRequestJudge: CaptureRequestJudge {
    let decisions: TeacherDecisions
    let fallback: any CaptureRequestJudge
    let threshold: Double
    let timeout: Duration

    init(
        decisions: TeacherDecisions,
        fallback: any CaptureRequestJudge = CaptureRequestDetector(),
        threshold: Double = 0.5,
        timeout: Duration = DecisionClient.defaultTimeout
    ) {
        self.decisions = decisions
        self.fallback = fallback
        self.threshold = threshold
        self.timeout = timeout
    }

    func isCaptureRequest(_ utterance: String) async -> Bool {
        guard let p = await decisions.captureRequestProbability(utterance, timeout: timeout) else {
            return await fallback.isCaptureRequest(utterance)
        }
        return p >= threshold
    }
}

// MARK: - 今、声をかけるべきか

/// 手が止まったときに、今声をかけるべきかを決める。
@MainActor
final class JevNudgeJudge {
    let decisions: TeacherDecisions
    let threshold: Double
    let timeout: Duration
    /// 規則ベースで「声をかける」とみなす手の止まった時間（分）。spec §3⑥ の初期値 3 分
    let stalledMinutesThreshold: Double

    init(
        decisions: TeacherDecisions,
        threshold: Double = 0.5,
        timeout: Duration = DecisionClient.defaultTimeout,
        stalledMinutesThreshold: Double = 3
    ) {
        self.decisions = decisions
        self.threshold = threshold
        self.timeout = timeout
        self.stalledMinutesThreshold = stalledMinutesThreshold
    }

    func shouldSpeakUp(_ context: NudgeContext) async -> Bool {
        guard let p = await decisions.shouldSpeakUpProbability(context, timeout: timeout) else {
            return Self.ruleShouldSpeakUp(context, stalledMinutesThreshold: stalledMinutesThreshold)
        }
        return p >= threshold
    }

    /// 問題に取り組んでいる最中に、顔は画面の前にあるのに手が一定時間止まっていたら声をかける。
    /// 先生が 1 分以内に話したばかりなら待つ
    nonisolated static func ruleShouldSpeakUp(_ context: NudgeContext, stalledMinutesThreshold: Double = 3) -> Bool {
        guard context.phase == .working, context.isFacePresent else { return false }
        if let since = context.minutesSinceTeacherSpoke, since < 1 { return false }
        return context.minutesStalled >= stalledMinutesThreshold
    }
}

// MARK: - 発話の意図

/// 発話の意図を Jev で判断し、使えなければ言い方で決める。
@MainActor
final class JevIntentClassifier {
    let decisions: TeacherDecisions
    let timeout: Duration

    init(decisions: TeacherDecisions, timeout: Duration = DecisionClient.defaultTimeout) {
        self.decisions = decisions
        self.timeout = timeout
    }

    func intent(_ utterance: String) async -> UtteranceIntent {
        if let intent = await decisions.intent(utterance, timeout: timeout) { return intent }
        return Self.ruleIntent(utterance)
    }

    /// 言い方による大まかな判定。答えと雑談は言葉だけでは分けにくいので「その他」にする
    nonisolated static func ruleIntent(_ utterance: String) -> UtteranceIntent {
        let text = DecisionText.normalize(utterance)
        let finish = ["終わり", "おわり", "おしまい", "やめたい", "やめる", "もうやだ"]
        let rest = ["休憩", "きゅうけい", "疲れた", "つかれた", "休みたい", "やすみたい"]
        let question = ["わかんない", "わからない", "分からない", "どうやって", "どうして", "なんで", "教えて", "おしえて"]
        if finish.contains(where: text.contains) { return .wantsToFinish }
        if rest.contains(where: text.contains) { return .wantsBreak }
        if question.contains(where: text.contains) || utterance.contains("？") || utterance.contains("?") { return .question }
        return .other
    }
}

enum DecisionText {
    /// 空白と句読点を取り除く（書き起こしは「これ、見て」「これ 見て！」のように揺れる）
    static func normalize(_ s: String) -> String {
        String(s.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.punctuationCharacters.contains($0)
        })
    }
}
