import Foundation
import Testing
@testable import HomeTeacher

struct HintLadderTests {
    static let thinking = ProblemAnalysis(
        kind: .thinking,
        problemSummary: "たて4cm、横6cmの長方形の面積",
        answer: "24cm²",
        answerVariants: ["24平方センチメートル"],
        solution: "4×6=24",
        hintSteps: ["何を求める？", "長さはどこに書いてある？", "面積の求め方は？", "4×6を一緒に。ということは？"]
    )

    static let writing = ProblemAnalysis(
        kind: .writing,
        problemSummary: "「わたしの宝物」で400字",
        answer: "",
        hintSteps: ["宝物を3つ言ってみよう", "はじめ・なか・おわりを決めよう", "具体的な場面をほめる"],
        essayGuidance: "400字・3段落"
    )

    // MARK: reading / thinking

    @Test func 助けを求めるたびに1段ずつ進み最後で止まる() {
        var ladder = HintLadder(analysis: Self.thinking)
        #expect(ladder.stage == .whatIsAsked)
        #expect(ladder.level == 1)
        #expect(ladder.currentHint == "何を求める？")

        expectStep(ladder.handle(.askedForHelp), true)
        #expect(ladder.stage == .whereToLook)
        expectStep(ladder.handle(.askedForHelp), true)
        #expect(ladder.stage == .approach)
        expectStep(ladder.handle(.askedForHelp), true)
        #expect(ladder.stage == .walkThrough)
        #expect(ladder.isAtLastStage)

        // 「答え教えて」をくり返しても、最後の段階に留まる（答えの段階はない）
        expectStep(ladder.handle(.askedForHelp), false)
        expectStep(ladder.handle(.askedForHelp), false)
        #expect(ladder.stage == .walkThrough)
        #expect(ladder.level == 4)
    }

    @Test func 違う答えは同じ段階で2回つまずいたら進む() {
        var ladder = HintLadder(analysis: Self.thinking)
        expectStep(ladder.handle(.wrongAttempt), false)
        #expect(ladder.stage == .whatIsAsked)
        #expect(ladder.wrongAttempts == 1)
        expectStep(ladder.handle(.wrongAttempt), true)
        #expect(ladder.stage == .whereToLook)
        #expect(ladder.wrongAttempts == 0)
    }

    @Test func 違う答え1回で進める設定() {
        var ladder = HintLadder(analysis: Self.thinking, wrongAttemptsToAdvance: 1)
        expectStep(ladder.handle(.wrongAttempt), true)
        #expect(ladder.stage == .whereToLook)
    }

    @Test func 段階が進むとつまずきの数は数え直す() {
        var ladder = HintLadder(analysis: Self.thinking)
        ladder.handle(.wrongAttempt)
        ladder.handle(.askedForHelp)
        #expect(ladder.stage == .whereToLook)
        expectStep(ladder.handle(.wrongAttempt), false)
        #expect(ladder.stage == .whereToLook)
    }

    @Test func 解けたらそれ以上進まない() {
        var ladder = HintLadder(analysis: Self.thinking)
        ladder.handle(.askedForHelp)
        ladder.handle(.solved)
        #expect(ladder.isSolved)
        expectStep(ladder.handle(.askedForHelp), false)
        #expect(ladder.stage == .whereToLook)
    }

    // MARK: writing

    @Test func 作文は整理から構成へ進み書いたものを撮影したら講評() {
        var ladder = HintLadder(analysis: Self.writing)
        #expect(ladder.stages == [.organize, .structure, .review])
        #expect(ladder.stage == .organize)

        // 「わからない」では先へ飛ばさない（問いを小さくする）
        expectStep(ladder.handle(.askedForHelp), false)
        #expect(ladder.stage == .organize)

        expectStep(ladder.handle(.stageCompleted), true)
        #expect(ladder.stage == .structure)

        // 構成から講評へは、書いたものを見てから
        expectStep(ladder.handle(.stageCompleted), false)
        expectStep(ladder.handle(.askedForHelp), false)
        #expect(ladder.stage == .structure)

        expectStep(ladder.handle(.submittedWriting), true)
        #expect(ladder.stage == .review)
        #expect(ladder.currentHint == "具体的な場面をほめる")
        expectStep(ladder.handle(.submittedWriting), false)
    }

    @Test func 作文以外は撮影で講評に飛ばない() {
        var ladder = HintLadder(analysis: Self.thinking)
        expectStep(ladder.handle(.submittedWriting), false)
        #expect(ladder.stage == .whatIsAsked)
    }

    // MARK: 先生のメモ

    @Test func 先生のメモに種類と段階と今のヒントと隠した正答が入る() {
        var ladder = HintLadder(analysis: Self.thinking)
        ladder.handle(.askedForHelp)
        let note = TeacherNote.make(analysis: Self.thinking, ladder: ladder)
        #expect(note.contains("thinking"))
        #expect(note.contains("2/4"))
        #expect(note.contains("どこを見ればよいか"))
        #expect(note.contains("長さはどこに書いてある？"))
        #expect(note.contains("正答（子どもに言わない）：24cm²"))
        #expect(note.contains("24平方センチメートル"))
        #expect(!note.contains("ということは？」と聞いて止め"))
    }

    @Test func 最後の段階のメモは答えを子どもに言わせる() {
        var ladder = HintLadder(analysis: Self.thinking)
        for _ in 0..<5 { ladder.handle(.askedForHelp) }
        let note = TeacherNote.make(analysis: Self.thinking, ladder: ladder)
        #expect(note.contains("4/4"))
        #expect(note.contains("「ということは？」と聞いて止め、最後のひと言は子どもに言わせる"))
    }

    @Test func 作文のメモには正答の行がなく進め方が入る() {
        let note = TeacherNote.make(analysis: Self.writing, ladder: HintLadder(analysis: Self.writing))
        #expect(note.contains("writing"))
        #expect(note.contains("1/3"))
        #expect(note.contains("400字・3段落"))
        #expect(note.contains("先生が文章を書いて見せない"))
        #expect(!note.contains("正答"))
    }

    @Test func メモはシステムプロンプトの最後に入る() throws {
        let note = TeacherNote.make(analysis: Self.thinking, ladder: HintLadder(analysis: Self.thinking))
        let system = try PromptLibrary().conversationSystemPrompt(mode: .study, teacherNote: note)
        #expect(system.hasSuffix(note))
        #expect(system.contains("先生のメモ（子どもには見せない・読み上げない）"))
    }

    // MARK: 助けを求める発話

    @Test(arguments: ["わからない", "えー、わかんない…", "答え教えて！", "こたえおしえて", "ヒントちょうだい", "もう無理", "ﾋﾝﾄ"])
    func 助けを求める発話(_ utterance: String) {
        #expect(HelpRequestDetector.isHelpRequest(utterance))
    }

    @Test(arguments: ["わかった！", "24かな？", "できた", "ねえ先生、これ見て"])
    func 助けを求めていない発話(_ utterance: String) {
        #expect(!HelpRequestDetector.isHelpRequest(utterance))
    }
}
