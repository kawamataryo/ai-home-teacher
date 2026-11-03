import Foundation

/// 問題の種類（spec §3②）。
enum ProblemKind: String, Codable, Sendable, CaseIterable {
    /// 資料・グラフ・表の読み取り
    case reading
    /// 算数・理科的な思考
    case thinking
    /// 作文・記述（正答がない）
    case writing

    var label: String {
        switch self {
        case .reading: "読み取り"
        case .thinking: "思考"
        case .writing: "作文"
        }
    }

    /// ヒントの段階の数。reading / thinking は4段、writing は3段（prompts/hint_ladder.md）。
    var stageCount: Int { HintStage.stages(for: self).count }
}

/// Sonnet の分析結果（report_analysis ツールの入力）。
///
/// strict tool use では全キーが必須なので、作文以外の `essayGuidance` や作文の `answer` は空文字で返る。
struct ProblemAnalysis: Codable, Equatable, Sendable {
    var kind: ProblemKind
    /// 問題文の要約（何を聞かれているか）
    var problemSummary: String
    /// 正答の短い形（例: 24cm²、イ、3/4）。子どもには見せない。作文は空文字
    var answer: String
    /// 正答の言いかえ（例: 0.75、4分の3、75%）。読み上げの検査（AnswerLeakGuard）に使う
    var answerVariants: [String]
    /// 解き方の説明。先生がヒントを考える材料で、読み上げない
    var solution: String
    /// ヒントの段階ごとの中身。段階の順に並ぶ（reading / thinking は4つ、writing は3つ）
    var hintSteps: [String]
    /// 作文の進め方の目安（題・条件・書けそうな題材）。作文以外は空文字
    var essayGuidance: String

    init(
        kind: ProblemKind,
        problemSummary: String,
        answer: String,
        answerVariants: [String] = [],
        solution: String = "",
        hintSteps: [String],
        essayGuidance: String = ""
    ) {
        self.kind = kind
        self.problemSummary = problemSummary
        self.answer = answer
        self.answerVariants = answerVariants
        self.solution = solution
        self.hintSteps = hintSteps
        self.essayGuidance = essayGuidance
    }

    /// ヒントの数を段階の数に揃える。足りなければ段階の一般的な言い方で埋め、多ければ切る。
    /// （strict でも配列の長さは指定できないため、デコードのあとで揃える）
    func normalized() -> ProblemAnalysis {
        var copy = self
        let stages = HintStage.stages(for: kind)
        let trimmed = hintSteps.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        copy.hintSteps = stages.enumerated().map { index, stage in
            if index < trimmed.count, !trimmed[index].isEmpty { return trimmed[index] }
            return stage.fallbackHint
        }
        copy.answer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.answerVariants = answerVariants
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return copy
    }
}

/// report_analysis ツールの定義。
enum AnalysisTool {
    static let name = "report_analysis"

    static let description = """
        撮影した問題を分析した結果を報告する。必ず1回だけ呼ぶ。
        正答は子どもには見せず、先生がヒントを考える材料にする。
        """

    static var inputSchema: JSONValue {
        Schema.object([
            ("kind", .object([
                "type": .string("string"),
                "enum": .array(ProblemKind.allCases.map { .string($0.rawValue) }),
                "description": .string("reading＝資料・グラフ・表の読み取り、thinking＝算数・理科的な思考、writing＝作文・記述"),
            ])),
            ("problem_summary", Schema.string("問題文の要約。何を答えればよいかがわかるように、子どもの学年の言葉で1〜2文")),
            ("answer", Schema.string("正答の短い形だけ（例：24cm²、イ、3/4、東京）。式や説明は入れない。作文は空文字")),
            ("answer_variants", Schema.array(
                Schema.string("正答の別の書き方"),
                description: "正答の言いかえ（例：0.75、4分の3、75%、二十四）。無ければ空の配列"
            )),
            ("solution", Schema.string("解き方の説明（先生用）。作文は空文字")),
            ("hint_steps", Schema.array(
                Schema.string("その段階で子どもにかける問いかけ。正答は書かない"),
                description: """
                    ヒントの段階ごとの中身を順に並べる。
                    reading / thinking は4つ：1 何を聞かれているか → 2 どこを見るか → 3 考え方 → 4 一緒にたどる（最後のひと言は子どもに言わせる）。
                    writing は3つ：1 書くことの整理 → 2 構成 → 3 講評の観点
                    """
            )),
            ("essay_guidance", Schema.string("作文の題・条件（文字数・段落）・書けそうな題材の方向。作文以外は空文字")),
        ])
    }

    /// `tools` 配列の1要素。strict にする。
    static var definition: JSONValue {
        .object([
            "name": .string(name),
            "description": .string(description),
            "strict": .bool(true),
            "input_schema": inputSchema,
        ])
    }

    /// `tool_choice`：report_analysis を必ず呼ばせる。
    static var toolChoice: JSONValue {
        .object(["type": .string("tool"), "name": .string(name)])
    }

    static func decode(_ input: JSONValue) throws -> ProblemAnalysis {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ProblemAnalysis.self, from: input.jsonData()).normalized()
    }
}
