import Foundation

/// 発話の意図（spec §3⑥）。順番は Jev に送る選択肢の順番。
enum UtteranceIntent: String, CaseIterable, Sendable {
    case question = "質問"
    case answer = "答え"
    case smallTalk = "雑談"
    case wantsBreak = "休憩したい"
    case wantsToFinish = "終わりたい"
    case other = "その他"
}

/// 子どもの答えが正しそうか（`score` の段階）。
enum AnswerLikelihood: Int, CaseIterable, Sendable {
    case likelyWrong = 0
    case unsure = 1
    case likelyCorrect = 2
}

/// 学習セッションの今の段階。「今、声をかけるべきか」の判断に使う。
enum StudyPhase: String, Sendable {
    /// 問題に取り組んでいる
    case working = "問題に取り組んでいる"
    /// 休憩中
    case onBreak = "休憩中"
    /// 先生がヒントを出したばかり
    case afterHint = "先生がヒントを出したばかり"
}

/// 「今、声をかけるべきか」を判断する材料。
struct NudgeContext: Sendable, Equatable {
    /// 手が止まっている時間（分）
    var minutesStalled: Double
    var phase: StudyPhase
    /// 先生が最後に話してからの時間（分）。わからなければ nil
    var minutesSinceTeacherSpoke: Double?
    /// 顔が画面の前にあるか
    var isFacePresent: Bool = true
}

/// 1 つの発話についての判断をまとめて聞いた結果。答えがなかった項目は nil。
struct UtteranceAnalysis: Sendable, Equatable {
    var addressedToTeacher: Double?
    var utteranceComplete: Double?
    var captureRequest: Double?
    var intent: UtteranceIntent?
}

/// アプリが Jev に聞く判断の定義（質問文）と、その答えの読み方。
/// どれも Jev が使えなければ nil を返すので、呼び出し側（Jev*Judge など）が規則ベースに切り替える。
struct TeacherDecisions: Sendable {
    let client: DecisionClient

    /// 状況の説明。どの質問でも state に入れる
    static let situation = "小学5年生の子どもが iPad の AI 家庭教師（「先生」）と声で話しながら家で勉強している。"
        + "まわりにはきょうだいや家族がいることもある。発話は音声認識の書き起こしで、句読点や誤字が揺れる。"

    // MARK: - 質問の定義

    enum Key {
        static let addressed = "addressed_to_teacher"
        static let complete = "utterance_complete"
        static let capture = "capture_request"
        static let nudge = "should_speak_up"
        static let intent = "intent"
        static let correctness = "answer_correctness"
    }

    static let addressedQuestion = DecisionQuestion.boolean(
        instructions: "この発話は先生（AI 家庭教師）に向けて話しかけたものか。",
        whenTrue: "先生への質問・相談・返事・呼びかけ",
        whenFalse: "独り言、問題文の読み上げ、きょうだいや家族との会話、テレビなどの音"
    )

    static let completeQuestion = DecisionQuestion.boolean(
        instructions: "子どもは言いたいことを言い終わったか。",
        whenTrue: "文として完結していて、先生が返事をしてよい",
        whenFalse: "「えっと」「あのね」「〜で」のように途中で止まっていて、まだ続きそう"
    )

    static let captureQuestion = DecisionQuestion.boolean(
        instructions: "子どもは先生にノートやプリント、問題を見てほしい（カメラで撮ってほしい）と頼んでいるか。",
        whenTrue: "「これ見て」「ここわかんない」「見てほしい」など、紙の上のものを見せたがっている",
        whenFalse: "見せる必要のない質問や雑談、返事"
    )

    static let nudgeQuestion = DecisionQuestion.boolean(
        instructions: "本物の家庭教師なら、今このタイミングで子どもに声をかけるべきか。",
        whenTrue: "長く手が止まって困っていそうなので「どこか考え中？」とやさしく声をかけた方がよい",
        whenFalse: "集中して考えている途中、休憩中、席を外している、先生が話したばかりなど、今は見守る方がよい"
    )

    static let intentQuestion = DecisionQuestion.choice(
        instructions: "この発話で子どもは何をしようとしているか。",
        options: [
            .init(name: UtteranceIntent.question.rawValue, description: "問題ややり方についてたずねている"),
            .init(name: UtteranceIntent.answer.rawValue, description: "問題の答えや考えを言っている"),
            .init(name: UtteranceIntent.smallTalk.rawValue, description: "勉強と関係のない話をしている"),
            .init(name: UtteranceIntent.wantsBreak.rawValue, description: "疲れた・休みたいと言っている"),
            .init(name: UtteranceIntent.wantsToFinish.rawValue, description: "今日の勉強をやめたい・終わりにしたいと言っている"),
            .init(name: UtteranceIntent.other.rawValue, description: "上のどれにも当てはまらない"),
        ]
    )

    static let correctnessQuestion = DecisionQuestion.score(
        instructions: "子どもの答えは問題の正しい答えと合っていそうか。",
        levels: [
            "違っていそう",
            "どちらとも言えない（答えになっていない・聞き取れない）",
            "合っていそう（表記や言い方の違いは気にしない）",
        ]
    )

    // MARK: - 発話についての判断

    /// 発話についての判断（先生への発話か・言い終わったか・撮影の依頼か・意図）を 1 回のリクエストで聞く
    func analyzeUtterance(_ utterance: String, teacherLastSaid: String? = nil, timeout: Duration? = nil) async -> UtteranceAnalysis? {
        let result = await client.decide(
            state: Self.utteranceState(utterance, teacherLastSaid: teacherLastSaid),
            questions: [
                Key.addressed: Self.addressedQuestion,
                Key.complete: Self.completeQuestion,
                Key.capture: Self.captureQuestion,
                Key.intent: Self.intentQuestion,
            ],
            timeout: timeout
        )
        guard let result else { return nil }
        return UtteranceAnalysis(
            addressedToTeacher: result[Key.addressed]?.probability,
            utteranceComplete: result[Key.complete]?.probability,
            captureRequest: result[Key.capture]?.probability,
            intent: result[Key.intent]?.choiceIndex.map { UtteranceIntent.allCases[$0] }
        )
    }

    /// 先生への発話である確率
    func addressedProbability(_ utterance: String, teacherLastSaid: String? = nil, timeout: Duration? = nil) async -> Double? {
        await boolean(Key.addressed, Self.addressedQuestion, Self.utteranceState(utterance, teacherLastSaid: teacherLastSaid), timeout)
    }

    /// 言い終わった確率
    func completeProbability(_ transcript: String, timeout: Duration? = nil) async -> Double? {
        await boolean(Key.complete, Self.completeQuestion, Self.utteranceState(transcript, teacherLastSaid: nil), timeout)
    }

    /// 撮影の依頼である確率
    func captureRequestProbability(_ utterance: String, timeout: Duration? = nil) async -> Double? {
        await boolean(Key.capture, Self.captureQuestion, Self.utteranceState(utterance, teacherLastSaid: nil), timeout)
    }

    /// 発話の意図
    func intent(_ utterance: String, timeout: Duration? = nil) async -> UtteranceIntent? {
        let result = await client.decide(
            state: Self.utteranceState(utterance, teacherLastSaid: nil),
            questions: [Key.intent: Self.intentQuestion],
            timeout: timeout
        )
        return result?[Key.intent]?.choiceIndex.map { UtteranceIntent.allCases[$0] }
    }

    // MARK: - そのほかの判断

    /// 今、声をかけるべき確率
    func shouldSpeakUpProbability(_ context: NudgeContext, timeout: Duration? = nil) async -> Double? {
        var fields = [
            "situation": Self.situation,
            "minutes_hands_stopped": Self.format(context.minutesStalled),
            "phase": context.phase.rawValue,
            "face_in_front_of_screen": context.isFacePresent ? "はい" : "いいえ",
        ]
        if let minutes = context.minutesSinceTeacherSpoke {
            fields["minutes_since_teacher_spoke"] = Self.format(minutes)
        }
        return await boolean(Key.nudge, Self.nudgeQuestion, .fields(fields), timeout)
    }

    /// 子どもの答えが正しそうか。規則では決められないので、Jev が使えなければ nil（Claude に任せる）
    func answerLikelihood(problem: String, expectedAnswer: String?, childAnswer: String, timeout: Duration? = nil) async -> AnswerLikelihood? {
        var fields = ["situation": Self.situation, "problem": problem, "child_answer": childAnswer]
        if let expectedAnswer { fields["correct_answer"] = expectedAnswer }
        let result = await client.decide(state: .fields(fields), questions: [Key.correctness: Self.correctnessQuestion], timeout: timeout)
        return result?[Key.correctness]?.scoreLevel.flatMap(AnswerLikelihood.init(rawValue:))
    }

    // MARK: - 内部

    private func boolean(_ key: String, _ question: DecisionQuestion, _ state: DecisionState, _ timeout: Duration?) async -> Double? {
        await client.decide(state: state, questions: [key: question], timeout: timeout)?[key]?.probability
    }

    static func utteranceState(_ utterance: String, teacherLastSaid: String?) -> DecisionState {
        var fields = ["situation": situation, "utterance": utterance]
        if let teacherLastSaid { fields["teacher_last_said"] = teacherLastSaid }
        return .fields(fields)
    }

    private static func format(_ minutes: Double) -> String {
        String(format: "%.1f", minutes)
    }
}
