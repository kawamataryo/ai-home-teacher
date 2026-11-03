import Foundation

extension StudySessionCoordinator {

    /// `line` が `lead` と同じ言葉で始まっていたら、その部分（と続く句読点・空白）を取り除く。
    /// 句読点・空白・「！」「？」の違いは無視して比べる。
    nonisolated static func droppingLeadEcho(_ line: String, lead: String) -> String {
        let ignored = CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines).union(CharacterSet(charactersIn: "！？!?、。…〜ー"))
        let key = lead.unicodeScalars.filter { !ignored.contains($0) }
        guard !key.isEmpty else { return line }
        var matched = 0
        var index = line.unicodeScalars.startIndex
        let scalars = line.unicodeScalars
        let keyArray = Array(key)
        while index < scalars.endIndex, matched < keyArray.count {
            let c = scalars[index]
            if ignored.contains(c) { index = scalars.index(after: index); continue }
            guard c == keyArray[matched] else { return line }
            matched += 1
            index = scalars.index(after: index)
        }
        guard matched == keyArray.count else { return line }
        while index < scalars.endIndex, ignored.contains(scalars[index]) { index = scalars.index(after: index) }
        return String(scalars[index...])
    }
}
