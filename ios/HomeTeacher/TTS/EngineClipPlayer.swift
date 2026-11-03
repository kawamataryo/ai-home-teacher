import AVFoundation
import Foundation

/// AVAudioEngine（AVAudioPlayerNode）で再生する
///
/// エコー対策（spec §3①）では、マイクと再生を同じ AVAudioEngine（`setVoiceProcessingEnabled(true)`）に通す。
/// 聞き取り側のエンジンができたら、`AudioClipPlayer` の代わりにこれへそのエンジンを渡す。
///
/// MP3 / WAV はいったん一時ファイルに書いて AVAudioFile で PCM にし、決まった形式（`outputFormat`）にそろえてから流す
/// （つなぐ形式を途中で変えないため）。実機（#9）では `.dataPlayedBack` が来ないことがあるので、長さ + `finishGrace` で打ち切る。
@MainActor
final class EngineClipPlayer: SpeechAudioPlayer {
    var finishGrace: TimeInterval = 1

    private let engine: AVAudioEngine
    private let node = AVAudioPlayerNode()
    private let outputFormat: AVAudioFormat
    private var clipDuration: TimeInterval?
    private var token = 0
    private var continuation: CheckedContinuation<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    init(engine: AVAudioEngine, outputFormat: AVAudioFormat? = nil) {
        self.engine = engine
        self.outputFormat = outputFormat
            ?? AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: self.outputFormat)
    }

    var currentTime: TimeInterval? {
        guard clipDuration != nil, node.isPlaying,
              let nodeTime = node.lastRenderTime, nodeTime.isSampleTimeValid,
              let playerTime = node.playerTime(forNodeTime: nodeTime)
        else { return nil }
        return max(0, Double(playerTime.sampleTime) / playerTime.sampleRate)
    }

    var duration: TimeInterval? { clipDuration }

    func play(_ speech: SynthesizedSpeech) async throws {
        stop()
        let buffer = try Self.decode(speech, to: outputFormat)
        if !engine.isRunning { try engine.start() }
        token += 1
        let id = token
        let length = Double(buffer.frameLength) / outputFormat.sampleRate
        clipDuration = length

        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                node.scheduleBuffer(buffer, at: nil, options: [.interrupts], completionCallbackType: .dataPlayedBack) { [weak self] _ in
                    Task { @MainActor in self?.finish(id) }
                }
                node.play()
                timeoutTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(length + (self?.finishGrace ?? 1)))
                    guard !Task.isCancelled else { return }
                    self?.finish(id)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.stop() }
        }
    }

    func stop() {
        token += 1
        // stop() は予約したバッファの完了コールバックを呼ぶが、token を進めたので無視される
        node.stop()
        clipDuration = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation?.resume()
        continuation = nil
    }

    private func finish(_ id: Int) {
        guard id == token else { return }
        stop()
    }

    /// 音声データを `format` の PCM にする
    static func decode(_ speech: SynthesizedSpeech, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "tts-\(UUID().uuidString).\(speech.format.rawValue)")
        try speech.audio.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let file = try AVAudioFile(forReading: url)
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0,
              let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)
        else { throw TTSError.noAudio }
        try file.read(into: source)
        if source.format == format { return source }

        guard let converter = AVAudioConverter(from: source.format, to: format) else { throw TTSError.playbackFailed }
        let ratio = format.sampleRate / source.format.sampleRate
        let capacity = AVAudioFrameCount((Double(source.frameLength) * ratio).rounded(.up)) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { throw TTSError.playbackFailed }
        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .endOfStream
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return source
        }
        if status == .error { throw conversionError ?? TTSError.playbackFailed }
        guard output.frameLength > 0 else { throw TTSError.noAudio }
        return output
    }
}
