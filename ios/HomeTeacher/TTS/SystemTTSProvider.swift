import AVFoundation
import Foundation

/// AVSpeechSynthesizer（ja-JP）。オフライン時や Worker が使えないときの予備
///
/// `write` で PCM を受け取り、WAV にまとめて返す（再生は ElevenLabs と同じ AVAudioPlayer）。
/// 文字タイミングは次の順で取る:
/// 1. マーカー（`toMarkerCallback` の単語マーカー）。シミュレーターの声では届かなかった
/// 2. `willSpeakRangeOfSpeechString`。`write` でも呼ばれる（シミュレーターで確認）。呼ばれた時点までに届いた
///    サンプル数を、その範囲の開始時刻とみなす（バッファ単位のおおまかな値）
/// 3. どちらもなければ、音声の長さに文字を均等に並べる
///
/// 実機（#9）では、最後の空バッファが届かないことがある。バッファが途切れて `idleTimeout` たったら終わりとみなす。
@MainActor
final class SystemTTSProvider: NSObject, TTSProvider {
    let identifier = "system"
    let format = TTSAudioFormat.wav

    /// 最後のバッファから、これだけ次が来なければ終わりとみなす
    var idleTimeout: Duration = .seconds(1)
    /// 最初のバッファを待つ上限
    var startTimeout: Duration = .seconds(5)
    var rate: Float = AVSpeechUtteranceDefaultSpeechRate
    var pitchMultiplier: Float = 1.0

    /// 合成中のもの。デリゲートはどのスレッドから呼ばれるかわからないので、ロック付きで持つ
    private nonisolated let active = CollectorRegistry()

    /// 日本語の声。端末にあるもののうち品質の高いもの
    nonisolated static func japaneseVoice() -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "ja-JP" }
        return voices.max { $0.quality.rawValue < $1.quality.rawValue } ?? AVSpeechSynthesisVoice(language: "ja-JP")
    }

    func synthesize(_ text: String) -> AsyncThrowingStream<TTSChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    let speech = try await self.render(text)
                    continuation.yield(TTSChunk(audio: speech.audio, alignment: speech.alignment))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func render(_ text: String) async throws -> (audio: Data, alignment: TTSAlignment?) {
        guard let voice = Self.japaneseVoice() else { throw TTSError.voiceUnavailable }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = rate
        utterance.pitchMultiplier = pitchMultiplier

        let synthesizer = AVSpeechSynthesizer()
        let collector = SynthesisCollector()
        synthesizer.delegate = self
        let key = ObjectIdentifier(synthesizer)
        active.set(collector, for: key)
        // 終わるまで synthesizer を手放さない（defer で使うので生きている）
        defer {
            synthesizer.stopSpeaking(at: .immediate)
            synthesizer.delegate = nil
            active.set(nil, for: key)
        }

        synthesizer.write(utterance, toBufferCallback: { buffer in
            collector.append(buffer)
        }, toMarkerCallback: { markers in
            collector.append(markers)
        })

        let clock = ContinuousClock()
        let startedAt = clock.now
        while true {
            try await Task.sleep(for: .milliseconds(30))
            let state = collector.state
            if state.finished { break }
            if let last = state.lastBufferAt {
                if clock.now - last >= idleTimeout { break }
            } else if clock.now - startedAt >= startTimeout {
                throw TTSError.timedOut
            }
        }

        let result = collector.state
        guard !result.samples.isEmpty, result.sampleRate > 0 else { throw TTSError.noAudio }
        let alignment = Self.alignment(for: text, result: result)
        return (WAVEncoder.encode(samples: result.samples, sampleRate: Int(result.sampleRate)), alignment)
    }

    /// 文字タイミングを組み立てる。範囲（UTF-16）ごとの開始サンプルを、文字ごとの時刻に広げる
    static func alignment(for text: String, result: SynthesisCollector.State) -> TTSAlignment? {
        let rate = result.sampleRate
        let totalFrames = result.samples.count
        guard rate > 0, totalFrames > 0, !text.isEmpty else { return nil }

        var marks: [(range: NSRange, frame: Int)]
        if !result.markers.isEmpty {
            // byteSampleOffset の単位がはっきりしない。全体のサンプル数を超えていたらバイト数とみなす
            let maxOffset = result.markers.map(\.offset).max() ?? 0
            let divisor = maxOffset > totalFrames ? max(1, result.bytesPerFrame) : 1
            marks = result.markers.map { ($0.range, $0.offset / divisor) }
        } else {
            marks = result.spokenRanges.map { ($0.range, $0.frame) }
        }
        marks.sort { $0.frame < $1.frame }
        let duration = Double(totalFrames) / rate

        // 文字（Character）ごとの UTF-16 の位置
        let characters = text.map(String.init)
        var utf16Starts: [Int] = []
        var offset = 0
        for character in characters {
            utf16Starts.append(offset)
            offset += character.utf16.count
        }

        var starts = [Double](repeating: -1, count: characters.count)
        for (index, mark) in marks.enumerated() {
            let begin = Double(mark.frame) / rate
            let next = index + 1 < marks.count ? Double(marks[index + 1].frame) / rate : duration
            let inRange = characters.indices.filter {
                utf16Starts[$0] >= mark.range.location && utf16Starts[$0] < mark.range.location + mark.range.length
            }
            guard !inRange.isEmpty else { continue }
            let step = max(0, next - begin) / Double(inRange.count)
            for (k, i) in inRange.enumerated() where starts[i] < 0 {
                starts[i] = begin + step * Double(k)
            }
        }
        // 範囲が取れなかった文字は、前後から埋める（全部なければ均等に並べる）
        if starts.allSatisfy({ $0 < 0 }) {
            let step = duration / Double(characters.count)
            starts = characters.indices.map { Double($0) * step }
        } else {
            var previous = 0.0
            for i in starts.indices {
                if starts[i] < 0 { starts[i] = previous } else { previous = max(previous, starts[i]) }
                starts[i] = max(starts[i], previous)
            }
        }
        let ends = starts.indices.map { i in i + 1 < starts.count ? max(starts[i], starts[i + 1]) : max(starts[i], duration) }
        return TTSAlignment(characters: characters, characterStartTimesSeconds: starts, characterEndTimesSeconds: ends)
    }
}

extension SystemTTSProvider: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        // 呼ばれた時点のサンプル数を記録する（MainActor に渡ってからだとずれるので、ここで取る）
        active.collector(for: ObjectIdentifier(synthesizer))?.markSpokenRange(characterRange)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        active.collector(for: ObjectIdentifier(synthesizer))?.markFinished()
    }
}

/// AVSpeechSynthesizer のコールバック（別スレッドから届く）で受け取ったものをためる
final class SynthesisCollector: @unchecked Sendable {
    struct Marker: Equatable, Sendable {
        var range: NSRange
        var offset: Int
    }

    struct SpokenRange: Equatable, Sendable {
        var range: NSRange
        /// 呼ばれた時点までに届いていたサンプル数
        var frame: Int
    }

    struct State: Sendable {
        var samples: [Int16] = []
        var sampleRate: Double = 0
        var bytesPerFrame = 0
        var markers: [Marker] = []
        var spokenRanges: [SpokenRange] = []
        var lastBufferAt: ContinuousClock.Instant?
        var finished = false
    }

    private let lock = NSLock()
    private var _state = State()

    var state: State { lock.withLock { _state } }

    func append(_ buffer: AVAudioBuffer) {
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        let frames = Int(pcm.frameLength)
        // 最後は空のバッファ（届かないこともある）
        guard frames > 0 else {
            lock.withLock { _state.finished = true }
            return
        }
        var samples: [Int16] = []
        samples.reserveCapacity(frames)
        // バッファは使い回されるので、ここでコピーする（1 チャンネル目だけ使う）
        if let data = pcm.int16ChannelData {
            samples.append(contentsOf: UnsafeBufferPointer(start: data[0], count: frames))
        } else if let data = pcm.floatChannelData {
            for i in 0..<frames {
                let value = max(-1, min(1, data[0][i]))
                samples.append(Int16(value * Float(Int16.max)))
            }
        } else if let data = pcm.int32ChannelData {
            for i in 0..<frames { samples.append(Int16(truncatingIfNeeded: data[0][i] >> 16)) }
        }
        let rate = pcm.format.sampleRate
        let bytesPerFrame = Int(pcm.format.streamDescription.pointee.mBytesPerFrame)
        lock.withLock {
            _state.samples += samples
            _state.sampleRate = rate
            _state.bytesPerFrame = bytesPerFrame
            _state.lastBufferAt = .now
        }
    }

    func append(_ markers: [AVSpeechSynthesisMarker]) {
        let words = markers.filter { $0.mark == .word }.map { Marker(range: $0.textRange, offset: $0.byteSampleOffset) }
        lock.withLock { _state.markers += words }
    }

    func markSpokenRange(_ range: NSRange) {
        lock.withLock { _state.spokenRanges.append(SpokenRange(range: range, frame: _state.samples.count)) }
    }

    func markFinished() {
        lock.withLock { _state.finished = true }
    }
}

/// 合成中の SynthesisCollector を synthesizer ごとに持つ
final class CollectorRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var collectors: [ObjectIdentifier: SynthesisCollector] = [:]

    func set(_ collector: SynthesisCollector?, for key: ObjectIdentifier) {
        lock.withLock { collectors[key] = collector }
    }

    func collector(for key: ObjectIdentifier) -> SynthesisCollector? {
        lock.withLock { collectors[key] }
    }
}

/// 16bit モノラルの PCM を WAV にする
enum WAVEncoder {
    static func encode(samples: [Int16], sampleRate: Int) -> Data {
        let dataSize = samples.count * 2
        var data = Data()
        data.reserveCapacity(44 + dataSize)
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))                // fmt チャンクの大きさ
        append(UInt16(1))                 // PCM
        append(UInt16(1))                 // モノラル
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))    // 1 秒あたりのバイト数
        append(UInt16(2))                 // 1 サンプルのバイト数
        append(UInt16(16))                // ビット数
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(dataSize))
        samples.withUnsafeBufferPointer { buffer in
            for sample in buffer { append(sample) }
        }
        return data
    }
}
