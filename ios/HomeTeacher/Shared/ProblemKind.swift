import Foundation

/// 問題の種類（spec §3②）。問題分析（Tutor）と記録・同期 API の `problems[].kind` で共通に使う。
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
