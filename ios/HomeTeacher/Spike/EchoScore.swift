import Foundation

/// 再生した文がマイクの認識結果にどれだけ混入したか（0〜1）。
/// 文字 bigram の一致率で見る。1 に近いほどエコーを拾っている。
enum EchoScore {
    static func leakage(played: String, recognized: String) -> Double {
        let p = bigrams(normalize(played))
        guard !p.isEmpty else { return 0 }
        let r = Set(bigrams(normalize(recognized)))
        let hit = p.filter(r.contains).count
        return Double(hit) / Double(p.count)
    }

    static func normalize(_ s: String) -> [Character] {
        let ignored = CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines).union(.symbols)
        return s.unicodeScalars.filter { !ignored.contains($0) }.map(Character.init)
    }

    static func bigrams(_ chars: [Character]) -> [String] {
        guard chars.count >= 2 else { return chars.map(String.init) }
        return (0..<(chars.count - 1)).map { String(chars[$0]) + String(chars[$0 + 1]) }
    }
}
