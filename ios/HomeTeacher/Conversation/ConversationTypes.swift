import Foundation

/// 会話の状態。アバターの表情や UI の表示にもそのまま使う。
enum ConversationState: Equatable, Sendable {
    /// 待機。マイクは開いているが、誰も話していない
    case idle
    /// 聞き取り中。子どもの発話を書き起こしている
    case listening
    /// 考え中。先生への発話として受け付け、応答を作っている
    case thinking
    /// 発話中。先生が話している
    case speaking
}

/// ConversationController が外へ知らせる出来事。
enum ConversationEvent: Equatable, Sendable {
    /// 先生が応答すべき発話。TeacherBrain に渡して応答を作る（状態は thinking になっている）
    case userTurnAccepted(String)
    /// 先生への発話ではないと判断して無視した発話（独り言・きょうだいの声など）
    case utteranceIgnored(String)
    /// 先生の考え中・発話中に子どもが話し始めた。
    /// TTS と Claude のストリームを止め、履歴を切り詰めるのは受け取った側（#13）の仕事
    case bargeIn(during: ConversationState)
}

/// 先生の発話中にマイクをどう扱うか。
enum SpeakingInputMode: Equatable, Sendable {
    /// マイクを開いたまま。子どもが話し始めたら割り込み（barge-in）として扱う
    case bargeIn
    /// 先生が話している間はマイクを止める（エコー対策の保険）
    case muteWhileSpeaking
}

/// 会話の設定。セッションごとに ConversationController を作るときに渡す。
struct ConversationSettings: Equatable, Sendable {
    /// 発話がこれで始まっていたら先生への呼びかけとみなす
    var callWords: [String]
    /// 先生の発話が終わってから、この時間内に話し始めた発話は会話の続きとして応答する
    var continuationWindow: Duration
    /// 声が止まってからこの時間無音が続いたら、言い終わったとみなす
    var endOfUtteranceSilence: Duration
    var speakingInputMode: SpeakingInputMode

    static let defaultCallWords = ["ねえ先生", "ねぇ先生", "ねえせんせい", "ねぇせんせい", "先生", "せんせい"]

    init(
        callWords: [String] = Self.defaultCallWords,
        continuationWindow: Duration = .seconds(30),
        endOfUtteranceSilence: Duration = .milliseconds(700),
        speakingInputMode: SpeakingInputMode = .bargeIn
    ) {
        self.callWords = callWords
        self.continuationWindow = continuationWindow
        self.endOfUtteranceSilence = endOfUtteranceSilence
        self.speakingInputMode = speakingInputMode
    }
}

/// `ConversationController.speak` の結果。
enum SpeakOutcome: Equatable, Sendable {
    /// 最後まで話した
    case completed
    /// 途中で子どもが割り込んだ（またはセッションが止まった）
    case interrupted
    /// 聞き取り中・発話中だったので話さなかった
    case rejected
}
