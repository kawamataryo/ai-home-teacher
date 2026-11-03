import Foundation

/// テストのバンドル（アプリの定型句の音声を含まない）。
/// アプリには ElevenLabs で作った定型句の音声（phrase_*.json）が同梱されているので、
/// キャッシュの読み書きを確かめるテストではこちらを渡し、同梱の音声に影響されないようにする。
private final class PhraseTestBundleToken {}

extension Bundle {
    static let withoutBundledPhrases = Bundle(for: PhraseTestBundleToken.self)
}
