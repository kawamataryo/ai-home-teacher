import Foundation

/// セッションの始まりに、前回の要約と覚えていることをシステムプロンプトに入れる（spec §3④）。
/// 中身は prompts/opening.md の `{{previous_session}}` に入り、会話用のプロンプトの後ろに足される。
///
/// 使い方:
/// ```swift
/// let builder = OpeningPromptBuilder()
/// let system = try await builder.conversationSystemPrompt(store: store)
/// let brain = TeacherBrain(client: client, systemPrompt: system, tools: try library.conversationTools())
/// ```
///
/// 「要確認」（flags）は入れない。深刻な話を先生から蒸し返さないように、親だけが見る。
struct OpeningPromptBuilder: Sendable {
    /// 1カテゴリあたり、プロンプトに入れる記憶の数（新しい順）。
    static let memoriesPerCategory = 8

    var library: PromptLibrary = PromptLibrary()
    var calendar: Calendar = .current

    /// 「前回のこと」の本文。前回のセッションも記憶もなければ nil。
    func previousSessionText(last: StudySessionRecord?, memories: [MemoryRecord], now: Date) -> String? {
        var lines: [String] = []
        if let last {
            lines += ["## 前回の勉強（\(relativeDayText(last.startedAt, now: now))）", ""]
            let summary = last.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append("- 要約：\(summary.isEmpty ? "（なし）" : summary)")
            if !last.problems.isEmpty {
                let problems = last.problems.map { "\($0.summary)（\($0.solvedBySelf ? "自力で解けた" : "まだ途中・一緒に解いた")）" }
                lines.append("- 取り組んだ問題：\(problems.joined(separator: "、"))")
            }
            let note = last.teacherNote.trimmingCharacters(in: .whitespacesAndNewlines)
            if !note.isEmpty {
                lines.append("- 先生からのひとこと：\(note)")
            }
        }

        let grouped = MemoryCategory.allCases.compactMap { category -> String? in
            let items = memories
                .filter { $0.category == category }
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(Self.memoriesPerCategory)
                .map(\.content)
            return items.isEmpty ? nil : "- \(category.label)：\(items.joined(separator: "、"))"
        }
        if !grouped.isEmpty {
            if !lines.isEmpty { lines.append("") }
            lines += ["## 覚えていること", ""] + grouped
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// 「今日」「昨日」「3日前」のように言う。
    func relativeDayText(_ date: Date, now: Date) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case ..<1: return "今日"
        case 1: return "昨日"
        case 2: return "おととい"
        default: return "\(days)日前"
        }
    }

    /// ストアから前回のことを読んで、会話用のシステムプロンプトを作る。
    func conversationSystemPrompt(
        store: some MemoryStore,
        mode: SessionMode = .study,
        now: Date = Date()
    ) async throws -> String {
        let text = previousSessionText(
            last: try await store.latestSession(),
            memories: try await store.memories(),
            now: now
        )
        return try library.conversationSystemPrompt(mode: mode, previousSession: text)
    }
}
