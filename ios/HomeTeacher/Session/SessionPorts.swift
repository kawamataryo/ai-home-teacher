import Foundation

/// 先生の声。1 文ずつ話し、割り込まれたら止めて「その文の何文字目まで話したか」を返す。
/// 本番は `TeacherVoice`（ElevenLabs → AVSpeechSynthesizer、再生はマイクと同じエンジンの `EngineClipPlayer`）。
@MainActor
protocol TeacherSpeaking: SpeechOutput {
    @discardableResult
    func stop() -> Int
}

extension TeacherVoice: TeacherSpeaking {}

/// 「勉強スタート」などのコマンドを聞き取ったあと、その文字を次の発話に持ち越さないようにできる音声入力。
@MainActor
protocol UtteranceDiscarding: AnyObject {
    func discardCurrentUtterance()
}

extension MicrophoneSpeechInput: UtteranceDiscarding {}

/// 同期（#28）。本番は `SyncService`。テストではモックで呼ばれたかだけを見る。
protocol SessionSyncing: Sendable {
    @discardableResult
    func syncNow(reason: SyncReason) async -> SyncReport
}

extension SyncService: SessionSyncing {}
