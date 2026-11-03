import Foundation
import Testing
@testable import HomeTeacher

/// 子どもの答えの判定（#73）：規則（正答との照合）→ Jev → Jev なしの規則
@MainActor
struct AnswerJudgeTests {
    static let analysis = ProblemAnalysis(
        kind: .thinking, problemSummary: "たて4cm、横6cmの長方形の面積を求める", answer: "24cm²",
        answerVariants: ["24平方センチメートル"], hintSteps: ["何を求める？", "長さはどこ？", "面積の求め方は？", "4×6は？"]
    )

    static func tutoring(_ analysis: ProblemAnalysis = analysis) -> TutoringState {
        TutoringState(analysis: analysis, ladder: HintLadder(analysis: analysis), leakGuard: AnswerLeakGuard(analysis: analysis))
    }

    /// 意図と正しそうかの答え（Jev の実際の形）
    static func jevAnswer(intent: String, score: Double) -> String {
        #"{"model":"jev-1.14.0","answers":{"intent":{"type":"choice","choice":"\#(intent)","confidence":0.9,"probabilities":{"\#(intent)":0.9}},"answer_correctness":{"type":"score","score":\#(score),"confidence":0.9,"probabilities":{"0":0.1,"1":0.1,"2":0.8}}},"usage":{"input_tokens":200,"output_tokens":4}}"#
    }

    private func judge(_ transport: MockTransport) -> AnswerJudge {
        AnswerJudge(decisions: DecisionFixture.decisions(transport))
    }

    @Test func 正答を言えばJevに聞かずに正解() async {
        let transport = MockTransport(body: "{}")
        for utterance in ["24平方センチ！", "わかった、24cm²だ", "答えは二十四平方センチメートル"] {
            let result = await judge(transport).judge(utterance, tutoring: Self.tutoring(), teacherLastSaid: nil)
            #expect(result == AnswerJudgement(verdict: .correct, source: .rule), "\(utterance)")
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test func 助けを求める発話は答えではない() async {
        let transport = MockTransport(body: "{}")
        let result = await judge(transport).judge("わかんない、答え教えて", tutoring: Self.tutoring(), teacherLastSaid: nil)
        #expect(result.verdict == .notAnAnswer)
        #expect(await transport.requests.isEmpty)
    }

    @Test(arguments: [
        // 実測（2026-11-03、jev-latest）に近い値
        ("答え", 1.99, AnswerVerdict.correct),   // 「にじゅうよん！」
        ("答え", 0.05, .wrong),                  // 「答えは20平方センチ？」
        ("答え", 0.36, .notAnAnswer),            // 「4と6」（途中の考え）
        ("答え", 1.36, .notAnAnswer),            // 「4かける6」
        ("質問", 1.99, .correct),                // 「24かな？」を聞く形で
        ("質問", 0.10, .notAnAnswer),            // 質問は違う答えにしない
        ("雑談", 0.56, .notAnAnswer),
    ])
    func Jevの意図と正しそうかで決める(intent: String, score: Double, expected: AnswerVerdict) async throws {
        let transport = MockTransport(body: Self.jevAnswer(intent: intent, score: score))
        let result = await judge(transport).judge("にじゅうよん", tutoring: Self.tutoring(), teacherLastSaid: "面積はどうやって求める？")
        #expect(result == AnswerJudgement(verdict: expected, source: .jev))

        // 1 回のリクエストで、意図と正しそうかをまとめて聞く
        #expect(await transport.requests.count == 1)
        let body = try await DecisionFixture.requestJSON(transport)
        let questions = try #require(body["questions"] as? [String: Any])
        #expect(Set(questions.keys) == [TeacherDecisions.Key.intent, TeacherDecisions.Key.correctness])
        let state = try #require(body["state"] as? [String: String])
        #expect(state["correct_answer"] == "24cm²")
        #expect(state["child_answer"] == "にじゅうよん")
        #expect(state["teacher_last_said"] == "面積はどうやって求める？")
    }

    @Test(arguments: [
        ("答えは20平方センチ？", AnswerVerdict.wrong),
        ("10かな", .wrong),
        ("4と6", .notAnAnswer),               // 数が 2 つ（途中の考え）
        ("4cmってどこに書いてある？", .notAnAnswer), // 質問
        ("長方形の面積だよね", .notAnAnswer),  // 数がない
    ])
    func Jevが使えなければ数の答えだけを規則で見る(utterance: String, expected: AnswerVerdict) async {
        let transport = MockTransport(status: 500, body: "{}")
        let result = await judge(transport).judge(utterance, tutoring: Self.tutoring(), teacherLastSaid: nil)
        #expect(result == AnswerJudgement(verdict: expected, source: .fallback))
    }

    @Test func Jevがなければ規則だけ() async {
        let result = await AnswerJudge(decisions: nil).judge("20平方センチ", tutoring: Self.tutoring(), teacherLastSaid: nil)
        #expect(result == AnswerJudgement(verdict: .wrong, source: .fallback))
    }

    @Test func 言葉の答えはJevなしでは違うと決めない() async {
        let word = ProblemAnalysis(kind: .reading, problemSummary: "いちばん多い月", answer: "8月", answerVariants: ["八月"], hintSteps: [])
        let wordText = ProblemAnalysis(kind: .reading, problemSummary: "都道府県", answer: "東京", hintSteps: [])
        #expect(await AnswerJudge(decisions: nil).judge("5月", tutoring: Self.tutoring(word), teacherLastSaid: nil).verdict == .wrong)
        #expect(await AnswerJudge(decisions: nil).judge("大阪", tutoring: Self.tutoring(wordText), teacherLastSaid: nil).verdict == .notAnAnswer)
    }

    @Test func 作文と解けたあとは判定しない() async {
        let transport = MockTransport(body: Self.jevAnswer(intent: "答え", score: 0))
        let essay = ProblemAnalysis(kind: .writing, problemSummary: "夏休みの思い出", answer: "", hintSteps: [])
        #expect(await judge(transport).judge("海に行った", tutoring: Self.tutoring(essay), teacherLastSaid: nil).verdict == .notAnAnswer)

        var solved = Self.tutoring()
        solved.ladder.handle(.solved)
        #expect(await judge(transport).judge("10", tutoring: solved, teacherLastSaid: nil).verdict == .notAnAnswer)
        #expect(await transport.requests.isEmpty)
    }

    // MARK: - ヒントの段階の変わり方

    @Test func 違う答えを2回で次の段階へ進めて励ます() {
        var state = Self.tutoring()
        #expect(state.react(to: "20？", verdict: .wrong) == .wrongAttempt(advanced: false))
        #expect(state.ladder.level == 1)
        #expect(state.ladder.wrongAttempts == 1)
        let reaction = state.react(to: "10？", verdict: .wrong)
        #expect(reaction == .wrongAttempt(advanced: true))
        #expect(state.ladder.level == 2)
        #expect(reaction.cue == ReplyCue(lead: nil, emotion: .encourage))
    }

    @Test func 解けたらほめて以降は答えを繰り返してよい() {
        var state = Self.tutoring()
        // Jev だけが正答とみなした（「にじゅうよん」は規則の照合に当たらない）
        let reaction = state.react(to: "にじゅうよん", verdict: .correct)
        #expect(reaction == .solved)
        #expect(reaction.cue == ReplyCue(lead: "すごいじゃん！", emotion: .praise))
        #expect(state.ladder.isSolved)
        #expect(state.leakGuard.check("そう、24cm²だね！") == .allowed)
        // 2 回目からは何も起きない（ほめ言葉を重ねない）
        #expect(state.react(to: "24", verdict: .correct) == .none)
    }

    @Test func 助けを求めたら1段進める() {
        var state = Self.tutoring()
        #expect(state.react(to: "わかんない", verdict: .notAnAnswer) == .advancedByHelp)
        #expect(state.react(to: "うーん", verdict: .notAnAnswer) == .none)
        #expect(state.ladder.level == 2)
        #expect(TutoringReaction.advancedByHelp.cue == nil)
    }

    @Test func 定型句は同梱の一覧にある() throws {
        let phrases = try PhraseCache.loadManifest()
        #expect(phrases.contains { $0.key == "sugoi_jan" && PhraseCache.normalize($0.text) == PhraseCache.normalize(ReplyCue.praisePhrase) })
    }

    // MARK: - 先生のメモ

    @Test func 先生のメモに違う答えの回数と励ましと解けたことを書く() {
        var state = Self.tutoring()
        state.react(to: "20？", verdict: .wrong)
        #expect(TeacherNote.make(analysis: state.analysis, ladder: state.ladder).contains("違う答えが1回あった"))
        let reaction = state.react(to: "10？", verdict: .wrong)
        let encourage = TeacherNote.make(analysis: state.analysis, ladder: state.ladder, reaction: reaction)
        #expect(encourage.contains("2回まちがえたので、段階を1つ進めた"))
        #expect(encourage.contains("[encourage]"))
        state.react(to: "24", verdict: .correct)
        let solved = TeacherNote.make(analysis: state.analysis, ladder: state.ladder, reaction: .solved)
        #expect(solved.contains("自分で答えにたどりついた"))
        #expect(solved.contains("すごいじゃん！"))
    }
}

/// 決まった判定を返すモック
@MainActor
final class ScriptedAnswerJudge: AnswerJudging {
    var verdicts: [AnswerVerdict]
    private(set) var utterances: [String] = []

    init(_ verdicts: [AnswerVerdict]) { self.verdicts = verdicts }

    func judge(_ utterance: String, tutoring: TutoringState, teacherLastSaid: String?) async -> AnswerJudgement {
        utterances.append(utterance)
        return AnswerJudgement(verdict: verdicts.isEmpty ? .notAnAnswer : verdicts.removeFirst(), source: .jev)
    }
}
