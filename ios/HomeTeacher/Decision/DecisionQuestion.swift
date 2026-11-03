import Foundation

// TypeSafe AI（Jev）の System One API。2026-11-03 に公式の OpenAPI（https://api.typesafe.ai/openapi.json）と
// https://docs.typesafe.ai/api/system-one で確認した形:
//
//   POST https://api.typesafe.ai/v1/systemone（アプリは Worker の /v1/decide を呼び、Worker がそのまま中継する）
//   リクエスト: { "model": "jev-latest", "state": <文字列 | オブジェクト | 配列>, "questions": { <名前>: <質問> } }
//     - 真偽:   { "type": "noul", "instructions": "...", "criteria": { "true": "...", "false": "..." }? }
//               ※ spec や Vercel AI SDK では `boolean` と呼ぶが、TypeSafe のネイティブ API での型名は `noul`
//     - 選択:   { "type": "choice", "instructions": "..."?, "criteria": { <選択肢名>: <説明> } }（1〜255 個）
//     - 段階:   { "type": "score", "instructions": "..."?, "criteria": [<段階0>, <段階1>, ...] }（1〜10 段、低い順）
//   レスポンス: { "model": "...", "answers": { <名前>: <答え> }, "usage": { "input_tokens", "output_tokens" } }
//     - noul:   { "type": "noul", "noul": 0.98 }（真である確率）
//     - choice: { "type": "choice", "choice": "<選択肢名>", "confidence": 0.7, "probabilities": { <選択肢名>: 0.8, ... } }
//     - score:  { "type": "score", "score": 1.7, "confidence": 0.9, "legend": { "0": "...", ... },
//                 "probabilities": { "0": 0.1, "1": 0.1, "2": 0.8 } }（score は確率で重みづけした段階の期待値）
//   1 回のリクエストに型の違う質問を混ぜてよく、同じ state に対して並列に答えが返る。

/// Jev に聞く質問 1 つ。
enum DecisionQuestion: Sendable, Equatable {
    /// はい / いいえ。答えは「はい」の確率（API の型名は `noul`）
    case boolean(instructions: String, whenTrue: String? = nil, whenFalse: String? = nil)
    /// 選択肢から 1 つ。`options` は順番つきで、答えは添字で返す
    case choice(instructions: String, options: [ChoiceOption])
    /// 低い順に並べた段階で評価する
    case score(instructions: String, levels: [String])

    struct ChoiceOption: Sendable, Equatable {
        /// API に送る名前（答えの `choice` と `probabilities` のキーになる）
        let name: String
        /// いつこの選択肢になるか
        let description: String
    }
}

extension DecisionQuestion: Encodable {
    private enum CodingKeys: String, CodingKey {
        case type, instructions, criteria
    }

    private struct BooleanCriteria: Encodable {
        let `true`: String?
        let `false`: String?
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .boolean(instructions, whenTrue, whenFalse):
            try container.encode("noul", forKey: .type)
            try container.encode(instructions, forKey: .instructions)
            if whenTrue != nil || whenFalse != nil {
                try container.encode(BooleanCriteria(true: whenTrue, false: whenFalse), forKey: .criteria)
            }
        case let .choice(instructions, options):
            try container.encode("choice", forKey: .type)
            try container.encode(instructions, forKey: .instructions)
            // JSON のオブジェクトなので順番は保たれない。答えは名前で受けて、こちらの順番の添字に直す
            let criteria = Dictionary(options.map { ($0.name, $0.description) }, uniquingKeysWith: { first, _ in first })
            try container.encode(criteria, forKey: .criteria)
        case let .score(instructions, levels):
            try container.encode("score", forKey: .type)
            try container.encode(instructions, forKey: .instructions)
            try container.encode(levels, forKey: .criteria)
        }
    }
}

/// 質問の答え。
enum DecisionAnswer: Sendable, Equatable {
    /// 「はい」の確率（0〜1）
    case boolean(probability: Double)
    /// 選ばれた選択肢の添字と、選択肢の順番に並べた確率
    case choice(index: Int, probabilities: [Double], confidence: Double?)
    /// 段階の期待値（0〜段階数-1、小数）。`level` はそれを四捨五入した段階
    case score(value: Double, level: Int, probabilities: [Double], confidence: Double?)

    var probability: Double? {
        if case let .boolean(p) = self { return p }
        return nil
    }

    var choiceIndex: Int? {
        if case let .choice(index, _, _) = self { return index }
        return nil
    }

    var scoreLevel: Int? {
        if case let .score(_, level, _, _) = self { return level }
        return nil
    }
}

/// 質問をまとめて投げる対象（state）。
enum DecisionState: Sendable, Equatable, Encodable {
    case text(String)
    /// 項目ごとに分けた文字列。JSON のオブジェクトとして送る
    case fields([String: String])

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .text(text): try container.encode(text)
        case let .fields(fields): try container.encode(fields)
        }
    }
}
