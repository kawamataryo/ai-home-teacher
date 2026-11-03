import Foundation

/// 送ったリクエストの本文（JSON）から system の文を取り出す。
/// 会話はプロンプトキャッシュのために system を text block の配列で送るので、どちらの形でも読めるようにする。
func systemText(_ json: [String: Any]?) -> String? {
    if let text = json?["system"] as? String { return text }
    guard let blocks = json?["system"] as? [[String: Any]] else { return nil }
    return blocks.compactMap { $0["text"] as? String }.joined()
}
