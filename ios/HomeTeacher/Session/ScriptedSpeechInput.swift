import Foundation

/// マイクを使わない音声入力。決まった出来事を外から流す。
/// 起動引数 `-autoSession` の自己テスト（実機でマイクなしに会話を通す）と、シミュレーターでの表示確認に使う。
@MainActor
final class ScriptedSpeechInput: SpeechInput {
    let events: AsyncStream<SpeechInputEvent>
    private let continuation: AsyncStream<SpeechInputEvent>.Continuation
    private(set) var mutedHistory: [Bool] = []

    init() {
        (events, continuation) = AsyncStream.makeStream(of: SpeechInputEvent.self)
    }

    func setMuted(_ muted: Bool) {
        mutedHistory.append(muted)
    }

    func send(_ event: SpeechInputEvent) {
        continuation.yield(event)
    }

    /// 話し始め → 書き起こし → 話し終わり、をまとめて流す
    func say(_ text: String) {
        send(.voiceStarted)
        send(.transcript(text))
        send(.voiceEnded)
    }
}
