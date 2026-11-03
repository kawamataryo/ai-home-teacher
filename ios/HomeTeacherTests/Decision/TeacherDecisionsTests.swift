import Foundation
import Testing
@testable import HomeTeacher

@Suite(.timeLimit(.minutes(1)))
struct TeacherDecisionsTests {
    private typealias Key = TeacherDecisions.Key

    @Test func 判断はどれもはいいいえで聞く() {
        let questions = [
            TeacherDecisions.addressedQuestion, TeacherDecisions.completeQuestion, TeacherDecisions.captureQuestion,
            TeacherDecisions.helpQuestion, TeacherDecisions.breakQuestion, TeacherDecisions.finishQuestion, TeacherDecisions.givesAnswerQuestion, TeacherDecisions.matchesAnswerQuestion,
        ]
        for question in questions {
            guard case let .boolean(instructions, whenTrue, whenFalse) = question else { Issue.record("noul ではない"); continue }
            #expect(!instructions.isEmpty)
            // 公式の勧め: 「いいえ」も具体的な場面で書く
            #expect(whenTrue?.isEmpty == false)
            #expect(whenFalse?.isEmpty == false)
        }
    }

    @Test func 確率の読み方は07と03() {
        #expect(DecisionReading(0.7) == .yes)
        #expect(DecisionReading(0.69) == .unsure)
        #expect(DecisionReading(0.31) == .unsure)
        #expect(DecisionReading(0.3) == .no)
    }

    @Test func 発話についての判断を1回のリクエストで聞く() async throws {
        let body = DecisionFixture.nouls([Key.addressed: 0.9, Key.complete: 0.85, Key.capture: 0.7, Key.help: 0.95])
        let transport = MockTransport(body: body)
        let analysis = await DecisionFixture.decisions(transport).analyzeUtterance(
            "ここわかんない", context: UtteranceContext(teacherLastSaid: "どこか考え中？")
        )
        #expect(analysis == UtteranceAnalysis(addressedToTeacher: 0.9, utteranceComplete: 0.85, captureRequest: 0.7, helpRequest: 0.95))
        #expect(await transport.requests.count == 1)

        let json = try await DecisionFixture.requestJSON(transport)
        #expect(json["model"] as? String == "jev-1.14.0")
        let state = try #require(json["state"] as? [String: String])
        #expect(state["utterance"] == "ここわかんない")
        #expect(state["teacher_last_said"] == "どこか考え中？")
        #expect(state["situation"] == TeacherDecisions.situation)
        #expect(state["problem"] == nil)
        let questions = try #require(json["questions"] as? [String: [String: Any]])
        #expect(Set(questions.keys) == [Key.addressed, Key.complete, Key.capture, Key.help, Key.breakRequest, Key.finishRequest])
        #expect(questions.values.allSatisfy { $0["type"] as? String == "noul" })
    }

    @Test func 問題に取り組み中なら答えの判定も同じリクエストで聞く() async throws {
        let body = DecisionFixture.nouls([
            Key.addressed: 0.9, Key.complete: 0.9, Key.capture: 0.05, Key.help: 0.05, Key.givesAnswer: 0.98, Key.matchesAnswer: 0.97,
        ])
        let transport = MockTransport(body: body)
        let context = UtteranceContext(problem: ProblemContext(problem: "たて3cm、横8cmの長方形の面積", correctAnswer: "24"))
        let analysis = await DecisionFixture.decisions(transport).analyzeUtterance("にじゅうよん", context: context)
        #expect(analysis?.givesAnswer == 0.98)
        #expect(analysis?.matchesAnswer == 0.97)
        let json = try await DecisionFixture.requestJSON(transport)
        let state = try #require(json["state"] as? [String: String])
        #expect(state["problem"] == "たて3cm、横8cmの長方形の面積")
        #expect(state["correct_answer"] == "24")
        let questions = try #require(json["questions"] as? [String: [String: Any]])
        #expect(questions.count == 8)
    }

    @Test func Jevが使えなければnil() async {
        let transport = MockTransport(status: 500, body: "")
        #expect(await DecisionFixture.decisions(transport).analyzeUtterance("これ見て", context: UtteranceContext()) == nil)
    }
}
