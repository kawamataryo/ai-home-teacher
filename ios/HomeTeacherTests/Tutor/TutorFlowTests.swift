import Foundation
import Testing
@testable import HomeTeacher

/// 撮影 → 分析 → 「答え教えて」→ 先生のメモ → Haiku の返事 → 読み上げ前の検査、を通しで確かめる。
struct TutorFlowTests {
    private func client(_ transport: MockTransport) -> WorkerClient {
        WorkerClient(baseURL: URL(string: "https://example.workers.dev")!, familyToken: "t", transport: transport)
    }

    @Test func 答え教えてと言われ続けても正答は読み上げない() async throws {
        // 1. Sonnet の分析
        let analyzerTransport = MockTransport(body: ProblemAnalyzerTests.response(blocks: [
            ProblemAnalyzerTests.toolUse("report_analysis", ProblemAnalyzerTests.thinkingInput),
        ]))
        let result = try await ProblemAnalyzer(client: client(analyzerTransport)).analyze(jpegData: Data([0xFF, 0xD8, 0xFF]))
        var ladder = HintLadder(analysis: result.analysis)
        var leakGuard = AnswerLeakGuard(analysis: result.analysis)

        // 2. 「答え教えて」をくり返す → 1段ずつ進み、4段目で止まる
        for utterance in ["わかんない", "答え教えて", "答え教えてよー", "答え教えて！"] {
            #expect(HelpRequestDetector.isHelpRequest(utterance))
            ladder.handle(.askedForHelp)
            leakGuard.noteChildUtterance(utterance)
        }
        #expect(ladder.stage == .walkThrough)
        #expect(ladder.level == 4)
        #expect(leakGuard.isActive)

        // 3. 先生のメモを Haiku のシステムプロンプトに入れる
        let note = TeacherNote.make(analysis: result.analysis, ladder: ladder)
        #expect(note.contains("正答（子どもに言わない）：24cm²"))
        #expect(note.contains("「ということは？」と聞いて止め"))
        let system = try PromptLibrary().conversationSystemPrompt(mode: .study, teacherNote: note)

        // 4. Haiku がうっかり答えを言っても、読み上げる文は差し替わる
        let haikuTransport = MockTransport(body: SSEFixture.textStream(["4×6を", "計算すると…", "答えは24cm²だよ。", "どうしてか考えてみて？"]))
        let brain = TeacherBrain(client: client(haikuTransport), systemPrompt: system)
        var spoken: [String] = []
        for try await sentence in await brain.respond(to: "答え教えて！") {
            spoken.append(leakGuard.screen(sentence))
        }
        #expect(spoken == ["4×6を計算すると…答えは24cm²だよ。", "どうしてか考えてみて？"].map(leakGuard.screen))
        #expect(spoken.first == AnswerLeakGuard.defaultReplacement)
        #expect(spoken.last == "どうしてか考えてみて？")
        #expect(!spoken.joined().contains("24"))

        let body = try #require(await haikuTransport.requestBodies().first)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect((json["system"] as? String)?.hasSuffix(note) == true)

        // 5. 子どもが自分で言えたら、先生は繰り返してほめてよい
        leakGuard.noteChildUtterance("ということは…24平方センチ！")
        ladder.handle(.solved)
        #expect(leakGuard.screen("そう、24cm²！どうしてそう思った？") == "そう、24cm²！どうしてそう思った？")
        #expect(TeacherNote.make(analysis: result.analysis, ladder: ladder).contains("どうしてそう思ったかを聞いて"))
    }
}
