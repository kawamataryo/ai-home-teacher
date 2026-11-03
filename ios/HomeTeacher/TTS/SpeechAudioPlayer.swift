import AVFoundation
import Foundation

/// 1 文ぶんの音声の再生。テストでは手で進めるモックに差し替える
@MainActor
protocol SpeechAudioPlayer: AnyObject {
    /// 再生して、最後まで再生するか `stop()` されたら戻る。再生を始められなければ投げる
    func play(_ speech: SynthesizedSpeech) async throws
    /// 再生中の位置（秒）。再生していなければ nil。口パクと「何文字目まで話したか」の時計
    var currentTime: TimeInterval? { get }
    /// 再生中の音声の長さ（秒）。再生していなければ nil
    var duration: TimeInterval? { get }
    func stop()
}

/// AVAudioPlayer で再生する
///
/// MP3（ElevenLabs）も WAV（AVSpeechSynthesizer）も、1 文ぶんをまとめてから再生する。
/// 文を受け取りきるまで待つぶん出だしは遅れるが、MP3 のフレームを自前でデコードしてつなぐより確実。
/// AVAudioSession の設定はマイク側（聞き取り）が持つので、ここでは触らない。
///
/// 実機（#9）では終わりの通知が来ないことがあるので、音声の長さ + `finishGrace` で打ち切る。
@MainActor
final class AudioClipPlayer: NSObject, SpeechAudioPlayer {
    var finishGrace: TimeInterval = 1

    private var player: AVAudioPlayer?
    private var continuation: CheckedContinuation<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    override init() {
        super.init()
    }

    var currentTime: TimeInterval? {
        guard let player, player.isPlaying else { return nil }
        return player.currentTime
    }

    var duration: TimeInterval? { player?.duration }

    func play(_ speech: SynthesizedSpeech) async throws {
        stop()
        let player = try AVAudioPlayer(data: speech.audio, fileTypeHint: speech.format.fileTypeHint)
        player.delegate = self
        guard player.prepareToPlay(), player.play() else { throw TTSError.playbackFailed }
        self.player = player
        let id = ObjectIdentifier(player)
        let limit = player.duration + finishGrace

        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                self.timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(limit))
                    guard !Task.isCancelled else { return }
                    self?.finish(id)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.stop() }
        }
    }

    func stop() {
        player?.stop()
        player = nil
        resume()
    }

    private func finish(_ id: ObjectIdentifier) {
        guard let player, ObjectIdentifier(player) == id else { return }
        stop()
    }

    private func resume() {
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation?.resume()
        continuation = nil
    }
}

extension AudioClipPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(player)
        Task { @MainActor [weak self] in self?.finish(id) }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let id = ObjectIdentifier(player)
        Task { @MainActor [weak self] in self?.finish(id) }
    }
}
