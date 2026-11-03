@preconcurrency import AVFoundation

/// AVAudioPCMBuffer は Sendable ではないため、合成済みの音声を actor 境界越しに渡す包み。
/// 渡したあとは送り手側で触らないこと。
struct PCMBuffers: @unchecked Sendable {
    let items: [AVAudioPCMBuffer]
}

/// マイク入力と再生を同じ AVAudioEngine に通す音声パイプライン。
/// voice processing（エコーキャンセル）を有効にすると、スピーカーの音がマイクに回り込みにくくなる。
final class AudioPipeline: @unchecked Sendable {
    let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let lock = NSLock()
    private var onBuffer: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var onLevel: (@Sendable (Float) -> Void)?

    private(set) var voiceProcessingEnabled = false

    func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
    }

    /// - Parameter voiceProcessing: エコーキャンセルを有効にするか（比較用に切り替えられる）
    func start(voiceProcessing: Bool,
               onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void,
               onLevel: @escaping @Sendable (Float) -> Void) throws {
        stop()
        lock.withLock {
            self.onBuffer = onBuffer
            self.onLevel = onLevel
        }
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(voiceProcessing)
        voiceProcessingEnabled = voiceProcessing

        if player.engine == nil { engine.attach(player) }
        engine.connect(player, to: engine.mainMixerNode, format: nil)

        // voice processing を切り替えると入力フォーマットが変わるので、ここで取り直す
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let (handler, level) = self.lock.withLock { (self.onBuffer, self.onLevel) }
            handler?(buffer)
            level?(Self.rms(buffer))
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        player.stop()
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
    }

    var inputFormat: AVAudioFormat { engine.inputNode.outputFormat(forBus: 0) }

    /// 合成済みの音声バッファを順に再生し、全部再生し終わったら返る。
    func play(_ pcm: PCMBuffers) async {
        let buffers = pcm.items
        guard let first = buffers.first else { return }
        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: first.format)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            for (i, b) in buffers.enumerated() {
                if i == buffers.count - 1 {
                    player.scheduleBuffer(b, completionCallbackType: .dataPlayedBack) { _ in cont.resume() }
                } else {
                    player.scheduleBuffer(b)
                }
            }
            player.play()
        }
    }

    static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
        return (sum / Float(buffer.frameLength)).squareRoot()
    }
}
