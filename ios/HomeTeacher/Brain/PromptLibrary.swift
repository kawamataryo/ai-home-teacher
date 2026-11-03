import Foundation

/// リポジトリの `prompts/` にあるプロンプト。アプリには `prompts/` フォルダごと同梱する（ios/project.yml）。
enum PromptName: String, CaseIterable, Sendable {
    /// キャラクター設定と話し方
    case teacher
    /// ヒントの段階と答えを言わないルール（spec §3②）
    case hintLadder = "hint_ladder"
    /// 安全ルール（spec §3④）
    case safety
    /// 黒板の部品カタログ（Sonnet が show_board / render_svg を使うとき）
    case boardCatalog = "board_catalog"
}

enum PromptError: Error, Equatable {
    case notFound(String)
}

/// 同梱したプロンプトを読み、`{{key}}` を差し込む。
struct PromptLibrary: Sendable {
    /// 先生の名前（仮）。後で子どもと相談して決める。
    static let defaultVariables: [String: String] = [
        "teacher_name": "ハル",
    ]

    private let bundle: Bundle
    private let subdirectory: String

    init(bundle: Bundle = .main, subdirectory: String = "prompts") {
        self.bundle = bundle
        self.subdirectory = subdirectory
    }

    /// プロンプトをそのまま読む（差し込みなし）。
    func raw(_ name: PromptName) throws -> String {
        guard let url = bundle.url(forResource: name.rawValue, withExtension: "md", subdirectory: subdirectory) else {
            throw PromptError.notFound("\(subdirectory)/\(name.rawValue).md")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// プロンプトを読み、`{{key}}` を差し込む。
    func load(_ name: PromptName, variables: [String: String] = [:]) throws -> String {
        Self.render(try raw(name), variables: Self.defaultVariables.merging(variables) { _, new in new })
    }

    /// プロンプトの区切り。evals/prompt.mjs と揃える。
    static let separator = "\n\n---\n\n"

    /// 会話（Haiku）用のシステムプロンプト。teacher → hint_ladder → safety の順につなぎ、
    /// 先生のメモ（Sonnet の分析結果。正答を含む）があれば最後に足す。
    /// 組み立て方を変えたら evals/prompt.mjs も合わせる。
    func conversationSystemPrompt(teacherNote: String? = nil, variables: [String: String] = [:]) throws -> String {
        var parts = try [PromptName.teacher, .hintLadder, .safety].map { try load($0, variables: variables) }
        if let note = teacherNote?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            parts.append(Self.teacherNoteSection(note))
        }
        return parts.joined(separator: Self.separator)
    }

    /// 問題の分析・黒板（Sonnet）用に足す部品カタログ。
    func boardCatalog(variables: [String: String] = [:]) throws -> String {
        try load(.boardCatalog, variables: variables)
    }

    static func teacherNoteSection(_ note: String) -> String {
        """
        # 先生のメモ（子どもには見せない・読み上げない）

        \(note)
        """
    }

    static func render(_ template: String, variables: [String: String]) -> String {
        variables.reduce(template) { text, pair in
            text.replacingOccurrences(of: "{{\(pair.key)}}", with: pair.value)
        }
    }
}
