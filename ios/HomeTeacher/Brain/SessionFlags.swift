import Foundation

/// 親のダッシュボードに「要確認」として残すメモ（spec §3④）。保存は #25 / #28 で行う。
struct ParentFlag: Equatable, Sendable, Codable {
    /// prompts/tools/flag_for_parent.json の `category` の enum と揃える。
    enum Category: String, Sendable, Codable, CaseIterable {
        case bullying
        case health
        case anxiety
        case family
        case selfHarm = "self_harm"
        case safety
        case other
    }

    let category: Category
    /// 子どもが話した内容の要約（親が読む）。
    let reason: String
    let createdAt: Date
}

/// 1回の学習セッションで記録したフラグ。今はメモリ上だけで持つ。
struct SessionFlags: Equatable, Sendable, Codable {
    private(set) var needsReview: [ParentFlag] = []

    var hasNeedsReview: Bool { !needsReview.isEmpty }

    mutating func record(_ flag: ParentFlag) {
        needsReview.append(flag)
    }

    mutating func removeAll() {
        needsReview.removeAll()
    }
}

/// Claude が呼ぶ `flag_for_parent` ツール。定義は prompts/tools/flag_for_parent.json。
enum ParentFlagTool {
    static let name = "flag_for_parent"

    /// ツールの入力を読む。reason が空なら nil。知らない category は other にする。
    static func parse(_ input: JSONValue, now: Date = Date()) -> ParentFlag? {
        guard let reason = input["reason"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !reason.isEmpty
        else { return nil }
        let category = input["category"]?.stringValue.flatMap(ParentFlag.Category.init(rawValue:)) ?? .other
        return ParentFlag(category: category, reason: reason, createdAt: now)
    }
}
