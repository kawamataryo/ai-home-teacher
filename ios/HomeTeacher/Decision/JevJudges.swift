import Foundation

// Jev の判断（UtteranceDecisionCache でまとめて聞いたもの）を使う判定と、Jev が使えないときの規則ベースの判定。
// 確率は DecisionReading（0.7 / 0.3）で読み、あいだの帯と失敗のときの決め方を判定ごとに書く。
// 失敗を「いいえ」として扱わない（公式の agent skill）。

// MARK: - 先生への発話か

/// 先生への発話かを Jev で判断する。
/// 呼びかけ語で始まる発話は Jev を待たずに受け付ける（はっきり呼ばれたら必ず応える）。
/// 「いいえ」のときだけ聞き流す。迷う帯と Jev が使えないときは受け付ける
/// （家で一人で勉強している子の声を黙って無視する方が、きょうだいへの声に返事するより困る）
@MainActor
final class JevAddressingJudge: AddressingJudge {
    let cache: UtteranceDecisionCache
    let fallback: CallWordAddressingJudge
    let timeout: Duration

    /// 先生が最後に話した文。発話の判断の state に入れる（返事かどうかの手がかり）
    var teacherLastSaid: String? {
        get { cache.teacherLastSaid }
        set { cache.teacherLastSaid = newValue }
    }

    init(
        cache: UtteranceDecisionCache,
        fallback: CallWordAddressingJudge = CallWordAddressingJudge(),
        timeout: Duration = DecisionClient.defaultTimeout
    ) {
        self.cache = cache
        self.fallback = fallback
        self.timeout = timeout
    }

    func isAddressedToTeacher(_ utterance: String) async -> Bool {
        if await fallback.isAddressedToTeacher(utterance) { return true }
        guard let p = await cache.analysis(for: utterance, within: timeout)?.addressedToTeacher else { return true }
        return DecisionReading(p) != .no
    }
}

// MARK: - 言い終わったか

/// 言い終わったかを Jev で判断する。ついでに発話のほかの判断も先に聞いておく（UtteranceDecisionCache）。
/// 途中で区切ると子どもの話をさえぎってしまうので、ほかの判断より高い確率（`Threshold.complete`）のときだけ true にする。
/// それ以外と Jev が使えないときは false を返し、ConversationController の無音のタイムアウトに任せる
@MainActor
final class JevEndOfUtteranceDecider: EndOfUtteranceDecider {
    let cache: UtteranceDecisionCache
    /// 無音のタイムアウト（初期値 700ms）より遅い答えは使われないので、短めに待つ（リクエストは止めない）
    let timeout: Duration

    init(cache: UtteranceDecisionCache, timeout: Duration = .milliseconds(400)) {
        self.cache = cache
        self.timeout = timeout
    }

    func isUtteranceComplete(_ transcript: String) async -> Bool {
        guard let p = await cache.analysis(for: transcript, within: timeout)?.utteranceComplete else { return false }
        return p >= TeacherDecisions.Threshold.complete
    }
}

// MARK: - 撮影の依頼か

/// 発話が撮影の依頼（ノートや問題を見てほしい）かを決める。
@MainActor
protocol CaptureRequestJudge: AnyObject {
    func isCaptureRequest(_ utterance: String) async -> Bool
}

/// 「見て」「わかんない」「見てほしい」などの言い方で撮影の依頼とみなす（Jev が使えないとき・迷うとき用）。
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

/// 撮影の依頼かを Jev で判断する。迷う帯と Jev が使えないときは `CaptureRequestDetector` で決める。
@MainActor
final class JevCaptureRequestJudge: CaptureRequestJudge {
    let cache: UtteranceDecisionCache
    let fallback: any CaptureRequestJudge
    let timeout: Duration

    init(
        cache: UtteranceDecisionCache,
        fallback: any CaptureRequestJudge = CaptureRequestDetector(),
        timeout: Duration = DecisionClient.defaultTimeout
    ) {
        self.cache = cache
        self.fallback = fallback
        self.timeout = timeout
    }

    func isCaptureRequest(_ utterance: String) async -> Bool {
        guard let p = await cache.analysis(for: utterance, within: timeout)?.captureRequest else {
            return await fallback.isCaptureRequest(utterance)
        }
        switch DecisionReading(p) {
        case .yes: return true
        case .no: return false
        case .unsure: return await fallback.isCaptureRequest(utterance)
        }
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
