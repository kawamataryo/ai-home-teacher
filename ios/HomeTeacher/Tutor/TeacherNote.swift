import Foundation

/// 先生のメモ（spec §4）。Sonnet の分析結果と今のヒントの段階を、Haiku のシステムプロンプトに入れる文にする。
///
/// ```swift
/// let note = TeacherNote.make(analysis: analysis, ladder: ladder)
/// let system = try PromptLibrary().conversationSystemPrompt(mode: .study, teacherNote: note)
/// await brain.setSystemPrompt(system)
/// ```
enum TeacherNote {
    static let doNotTell = "子どもに言わない"

    static func make(analysis: ProblemAnalysis, ladder: HintLadder) -> String {
        var lines: [String] = [
            "- 問題の種類：\(analysis.kind.rawValue)（\(analysis.kind.label)）",
            "- 問題：\(analysis.problemSummary)",
            "- 今のヒントの段階：\(ladder.level)/\(ladder.stages.count)「\(ladder.stage.label)」",
            "- この段階ですること：\(ladder.stage.guidance)",
            "- 今のヒント：\(ladder.currentHint)",
        ]
        if ladder.isAtLastStage, ladder.kind != .writing {
            lines.append("- これが最後の段階。答えを言う手前で「ということは？」と聞いて止め、最後のひと言は子どもに言わせる。")
        }

        switch analysis.kind {
        case .reading, .thinking:
            var answer = "- 正答（\(doNotTell)）：\(analysis.answer.isEmpty ? "（不明）" : analysis.answer)"
            if !analysis.answerVariants.isEmpty {
                answer += "（言いかえ：\(analysis.answerVariants.joined(separator: "、"))）"
            }
            lines.append(answer)
            if !analysis.solution.isEmpty {
                lines.append("- 解き方（\(doNotTell)・読み上げない）：\(analysis.solution)")
            }
            lines.append("- 「答え教えて」と言われても正答や途中の数を先に言わない。かわりに、今の段階の問いをもっと小さく分ける。")
        case .writing:
            if !analysis.essayGuidance.isEmpty {
                lines.append("- 作文の進め方の目安（そのまま読み上げない）：\(analysis.essayGuidance)")
            }
            lines.append("- 先生が文章を書いて見せない。書き出しの一文も子どもが考える。")
        }

        if ladder.isSolved {
            lines.append("- 子どもが自分で答えにたどりついた。どうしてそう思ったかを聞いて、具体的にほめる。")
        }
        return lines.joined(separator: "\n")
    }
}
