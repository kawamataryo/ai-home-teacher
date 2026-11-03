import Foundation

/// 発話が先生への呼びかけかどうかを決める。
/// 既定は呼びかけ語による規則ベース。#31 で Jev を使う実装に差し替える。
/// （先生の発話から 30 秒以内の続きは、これを呼ばずに ConversationController が受け付ける）
@MainActor
protocol AddressingJudge: AnyObject {
    func isAddressedToTeacher(_ utterance: String) async -> Bool
}

/// 言い終わったかどうかを、無音のタイムアウトより早く決める（Jev など）。
/// false なら無音のタイムアウトを待つ。
@MainActor
protocol EndOfUtteranceDecider: AnyObject {
    func isUtteranceComplete(_ transcript: String) async -> Bool
}

/// 「ねえ先生」「先生」などで始まる発話を呼びかけとみなす。
@MainActor
final class CallWordAddressingJudge: AddressingJudge {
    let callWords: [String]

    init(callWords: [String] = ConversationSettings.defaultCallWords) {
        self.callWords = callWords
    }

    func isAddressedToTeacher(_ utterance: String) async -> Bool {
        Self.startsWithCallWord(utterance, callWords: callWords)
    }

    /// 空白と句読点を無視して先頭を比べる（書き起こしは「ねえ、先生」「 先生！」のように揺れる）
    nonisolated static func startsWithCallWord(_ utterance: String, callWords: [String]) -> Bool {
        let text = normalize(utterance)
        return callWords.contains { word in
            let w = normalize(word)
            return !w.isEmpty && text.hasPrefix(w)
        }
    }

    private nonisolated static func normalize(_ s: String) -> String {
        String(s.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.punctuationCharacters.contains($0)
        })
    }
}
