@preconcurrency import AVFoundation
import Observation
import UIKit

/// #9 実機スパイク：日本語の音声認識と、再生中のエコー混入を確かめる。
@MainActor @Observable
final class SpeechSpikeModel {
    struct EchoTrial: Identifiable {
        let id = UUID()
        let engine: RecognizerKind
        let voiceProcessing: Bool
        let leakage: Double
        let recognizedDuringPlayback: String
    }

    static let echoSentence = "こんにちは、今日もいっしょにがんばろう。まずは昨日の割合の問題から始めようか。"

    var support: LocaleSupport?
    var engine: RecognizerKind = .speechTranscriber
    var voiceProcessing = true
    var isListening = false
    var finalText = ""
    var volatileText = ""
    var level: Float = 0
    var status = ""
    var trials: [EchoTrial] = []
    var isEchoTesting = false

    private let pipeline = AudioPipeline()
    private var recognizer: (any LiveRecognizer)?
    private let synthesizer = AVSpeechSynthesizer()

    var transcript: String { finalText + volatileText }

    func probe() async {
        let s = await SpeechSupportProbe.probe()
        support = s
        if let p = s.preferred { engine = p }
    }

    func toggleListening() async {
        if isListening { await stopListening() } else { await startListening() }
    }

    func startListening() async {
        guard await AVAudioApplication.requestRecordPermission() else {
            status = "マイクが許可されていません"
            return
        }
        do {
            try pipeline.configureSession()
            let r: any LiveRecognizer = engine == .sfSpeechRecognizer ? SFRecognizer() : AnalyzerRecognizer(kind: engine)
            recognizer = r
            finalText = ""
            volatileText = ""
            try pipeline.start(
                voiceProcessing: voiceProcessing,
                onBuffer: { [weak r] in r?.append($0) },
                onLevel: { [weak self] v in Task { @MainActor in self?.level = v } }
            )
            try await r.start(inputFormat: pipeline.inputFormat) { [weak self] text, isFinal in
                Task { @MainActor in self?.receive(text, isFinal: isFinal) }
            }
            isListening = true
            status = "\(engine.rawValue) で聞き取り中（エコーキャンセル: \(voiceProcessing ? "ON" : "OFF")）"
        } catch {
            status = "開始に失敗: \(error.localizedDescription)"
            pipeline.stop()
        }
    }

    func stopListening() async {
        pipeline.stop()
        await recognizer?.stop()
        recognizer = nil
        isListening = false
        level = 0
        status = "停止しました"
    }

    private func receive(_ text: String, isFinal: Bool) {
        switch engine {
        case .sfSpeechRecognizer:
            // SFSpeechRecognizer は毎回全文を返す
            volatileText = text
            if isFinal { finalText += text; volatileText = "" }
        default:
            if isFinal { finalText += text; volatileText = "" } else { volatileText = text }
        }
    }

    /// 聞き取り中に先生の声（TTS）を流し、それがどれだけ認識結果に混入するかを測る。
    func runEchoTest() async {
        if !isListening { await startListening() }
        guard isListening else { return }
        isEchoTesting = true
        defer { isEchoTesting = false }
        let before = transcript
        status = "再生中…（黙って聞いてください）"
        let buffers = await synthesize(Self.echoSentence)
        trace("合成完了 buffers=\(buffers.items.count) frames=\(buffers.items.reduce(0) { $0 + Int($1.frameLength) })")
        await pipeline.play(buffers)
        trace("再生完了")
        try? await Task.sleep(for: .seconds(2))
        let during = String(transcript.dropFirst(before.count))
        let leak = EchoScore.leakage(played: Self.echoSentence, recognized: during)
        trials.insert(EchoTrial(engine: engine, voiceProcessing: voiceProcessing, leakage: leak, recognizedDuringPlayback: during), at: 0)
        status = String(format: "エコー混入率 %.0f%%", leak * 100)
    }

    /// AVAudioPCMBuffer は Sendable ではないので、合成コールバックから受け渡すために包む。
    private final class BufferBox: @unchecked Sendable {
        let lock = NSLock()
        var items: [AVAudioPCMBuffer] = []
        var done = false
    }

    private func synthesize(_ text: String) async -> PCMBuffers {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "ja-JP")
        let box = BufferBox()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            // 終端（長さ 0 のバッファ）が来ない端末があるため、10 秒で打ち切る
            let finish: @Sendable () -> Void = {
                let shouldResume = box.lock.withLock { () -> Bool in
                    guard !box.done else { return false }
                    box.done = true
                    return true
                }
                if shouldResume { cont.resume() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: finish)
            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else { finish(); return }
                box.lock.withLock { if !box.done { box.items.append(pcm) } }
            }
        }
        return PCMBuffers(items: box.lock.withLock { box.items })
    }

    /// issue に貼るための結果レポート。
    var report: String {
        var lines = ["### #9 実機スパイク結果", "- 端末: \(UIDevice.current.model) / iOS \(UIDevice.current.systemVersion)"]
        if let s = support {
            lines += [
                "- SpeechTranscriber: isAvailable=\(s.speechTranscriberAvailable), ja対応=\(s.speechTranscriberSupportsJa), ja導入済み=\(s.speechTranscriberInstalledJa)",
                "- DictationTranscriber: ja対応=\(s.dictationSupportsJa), ja導入済み=\(s.dictationInstalledJa)",
                "- SFSpeechRecognizer: ja対応=\(s.sfSupportsJa), 端末内=\(s.sfOnDeviceJa)",
                "- 推奨エンジン: \(s.preferred?.rawValue ?? "なし")",
            ]
        }
        lines.append("- エコーテスト:")
        for t in trials.reversed() {
            lines.append(String(format: "  - %@ / エコーキャンセル %@ → 混入率 %.0f%%（認識: 「%@」）",
                                t.engine.rawValue, t.voiceProcessing ? "ON" : "OFF", t.leakage * 100, t.recognizedDuringPlayback))
        }
        lines.append("- 最後の認識テキスト: 「\(transcript)」")
        return lines.joined(separator: "\n")
    }

    func copyReport() {
        UIPasteboard.general.string = report
        status = "結果をコピーしました。issue #9 に貼ってください"
    }

    /// 起動引数 `-autoSpike` で、人が話さなくても測れる項目を自動で実行する。
    /// 推奨エンジンでエコーキャンセル ON / OFF の両方を試し、結果をログと Documents/spike-report.txt に出す。
    /// 自動検証の進み具合を Documents/spike-trace.txt に追記する（どこで止まったかを Mac から見るため）。
    func trace(_ message: String) {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = dir.appending(path: "spike-trace.txt")
        let line = "\(Date().formatted(.iso8601)) \(message)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static var isAutoRun: Bool { ProcessInfo.processInfo.arguments.contains("-autoSpike") }

    func runAutomatic() async {
        trace("開始 engine=\(engine.rawValue)")
        for vp in [true, false] {
            voiceProcessing = vp
            trace("聞き取り開始 vp=\(vp)")
            await startListening()
            trace("聞き取り開始後 isListening=\(isListening) status=\(status)")
            // SpeechAnalyzer の日本語モデルのダウンロードと準備を待つ
            try? await Task.sleep(for: .seconds(4))
            trace("エコーテスト開始")
            await runEchoTest()
            trace("エコーテスト後 status=\(status)")
            await stopListening()
            trace("停止")
        }
        let text = report
        print("SPIKE_REPORT_BEGIN\n\(text)\nSPIKE_REPORT_END")
        if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? text.write(to: dir.appending(path: "spike-report.txt"), atomically: true, encoding: .utf8)
        }
        status = "自動検証が終わりました"
    }
}
