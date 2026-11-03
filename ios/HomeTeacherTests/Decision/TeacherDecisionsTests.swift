import Foundation
import Testing
@testable import HomeTeacher

@Suite(.timeLimit(.minutes(1)))
struct TeacherDecisionsTests {
    private typealias Key = TeacherDecisions.Key

    @Test func 判断ごとの質問の型() {
        func type(_ q: DecisionQuestion) -> String {
            switch q {
            case .boolean: "boolean"
            case .choice: "choice"
            case .score: "score"
            }
        }
        #expect(type(TeacherDecisions.addressedQuestion) == "boolean")
        #expect(type(TeacherDecisions.completeQuestion) == "boolean")
        #expect(type(TeacherDecisions.captureQuestion) == "boolean")
        #expect(type(TeacherDecisions.nudgeQuestion) == "boolean")
        #expect(type(TeacherDecisions.intentQuestion) == "choice")
        #expect(type(TeacherDecisions.correctnessQuestion) == "score")
    }

    @Test func 意図の選択肢はspecの6つの順番() throws {
        guard case let .choice(_, options) = TeacherDecisions.intentQuestion else { Issue.record(); return }
        #expect(options.map(\.name) == ["質問", "答え", "雑談", "休憩したい", "終わりたい", "その他"])
        #expect(options.map(\.name) == UtteranceIntent.allCases.map(\.rawValue))
    }

    @Test func 発話についての判断を1回のリクエストで聞く() async throws {
        let body = """
        {"model":"jev-latest","answers":{
          "\(Key.addressed)":{"type":"noul","noul":0.9},
          "\(Key.complete)":{"type":"noul","noul":0.85},
          "\(Key.capture)":{"type":"noul","noul":0.7},
          "\(Key.intent)":{"type":"choice","choice":"質問","confidence":0.6,"probabilities":{"質問":0.6,"答え":0.2,"その他":0.2}}
        }}
        """
        let transport = MockTransport(body: body)
        let analysis = await DecisionFixture.decisions(transport).analyzeUtterance("ここわかんない", teacherLastSaid: "どこか考え中？")
        #expect(analysis == UtteranceAnalysis(addressedToTeacher: 0.9, utteranceComplete: 0.85, captureRequest: 0.7, intent: .question))
        #expect(await transport.requests.count == 1)

        let json = try await DecisionFixture.requestJSON(transport)
        let state = try #require(json["state"] as? [String: String])
        #expect(state["utterance"] == "ここわかんない")
        #expect(state["teacher_last_said"] == "どこか考え中？")
        #expect(state["situation"] == TeacherDecisions.situation)
        let questions = try #require(json["questions"] as? [String: [String: Any]])
        #expect(Set(questions.keys) == [Key.addressed, Key.complete, Key.capture, Key.intent])
    }

    @Test func 声をかけるべきかは止まっている時間と段階をstateに入れる() async throws {
        let transport = MockTransport(body: DecisionFixture.noul(Key.nudge, 0.75))
        let p = await DecisionFixture.decisions(transport).shouldSpeakUpProbability(
            NudgeContext(minutesStalled: 3.5, phase: .working, minutesSinceTeacherSpoke: 4)
        )
        #expect(p == 0.75)
        let json = try await DecisionFixture.requestJSON(transport)
        let state = try #require(json["state"] as? [String: String])
        #expect(state["minutes_hands_stopped"] == "3.5")
        #expect(state["phase"] == "問題に取り組んでいる")
        #expect(state["minutes_since_teacher_spoke"] == "4.0")
        #expect(state["face_in_front_of_screen"] == "はい")
        let q = try #require((json["questions"] as? [String: [String: Any]])?[Key.nudge])
        #expect(q["type"] as? String == "noul")
    }

    @Test func 答えが正しそうかを段階で返す() async throws {
        let body = #"{"answers":{"\#(Key.correctness)":{"type":"score","score":1.9,"confidence":0.9,"probabilities":{"0":0.05,"1":0.05,"2":0.9}}}}"#
        let transport = MockTransport(body: body)
        let likelihood = await DecisionFixture.decisions(transport).answerLikelihood(problem: "3/4 は何%？", expectedAnswer: "75%", childAnswer: "75パーセント")
        #expect(likelihood == .likelyCorrect)
        let json = try await DecisionFixture.requestJSON(transport)
        let state = try #require(json["state"] as? [String: String])
        #expect(state["correct_answer"] == "75%")
        #expect(state["child_answer"] == "75パーセント")
        let q = try #require((json["questions"] as? [String: [String: Any]])?[Key.correctness])
        #expect(q["type"] as? String == "score")
        #expect((q["criteria"] as? [String])?.count == 3)
    }

    @Test func Jevが使えなければ答えの判定はnil() async {
        let transport = MockTransport(status: 500, body: "")
        #expect(await DecisionFixture.decisions(transport).answerLikelihood(problem: "1+1", expectedAnswer: "2", childAnswer: "2") == nil)
    }
}
