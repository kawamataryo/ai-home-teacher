@preconcurrency import AVFoundation
import Speech

/// 認識エンジンの種類。spec §3①: SpeechTranscriber → DictationTranscriber → SFSpeechRecognizer の順に試す。
enum RecognizerKind: String, CaseIterable, Sendable {
    case speechTranscriber = "SpeechTranscriber"
    case dictationTranscriber = "DictationTranscriber"
    case sfSpeechRecognizer = "SFSpeechRecognizer"
}

struct LocaleSupport: Sendable {
    var speechTranscriberAvailable = false
    var speechTranscriberSupportsJa = false
    var speechTranscriberInstalledJa = false
    var dictationSupportsJa = false
    var dictationInstalledJa = false
    var sfSupportsJa = false
    var sfOnDeviceJa = false

    var preferred: RecognizerKind? {
        if speechTranscriberAvailable && speechTranscriberSupportsJa { return .speechTranscriber }
        if dictationSupportsJa { return .dictationTranscriber }
        if sfSupportsJa { return .sfSpeechRecognizer }
        return nil
    }
}

enum Japanese {
    static let locale = Locale(identifier: "ja-JP")

    static func matches(_ l: Locale) -> Bool {
        l.language.languageCode?.identifier == "ja"
    }
}

enum SpeechSupportProbe {
    static func probe() async -> LocaleSupport {
        var s = LocaleSupport()
        s.speechTranscriberAvailable = SpeechTranscriber.isAvailable
        s.speechTranscriberSupportsJa = await SpeechTranscriber.supportedLocales.contains(where: Japanese.matches)
        s.speechTranscriberInstalledJa = await SpeechTranscriber.installedLocales.contains(where: Japanese.matches)
        s.dictationSupportsJa = await DictationTranscriber.supportedLocales.contains(where: Japanese.matches)
        s.dictationInstalledJa = await DictationTranscriber.installedLocales.contains(where: Japanese.matches)
        let sf = SFSpeechRecognizer(locale: Japanese.locale)
        s.sfSupportsJa = sf != nil
        s.sfOnDeviceJa = sf?.supportsOnDeviceRecognition ?? false
        return s
    }
}

/// 認識結果（確定 / 途中）を受け取る共通インターフェース。
protocol LiveRecognizer: AnyObject, Sendable {
    func start(inputFormat: AVAudioFormat, onText: @escaping @Sendable (String, Bool) -> Void) async throws
    func append(_ buffer: AVAudioPCMBuffer)
    func stop() async
}

/// SpeechAnalyzer（SpeechTranscriber / DictationTranscriber）による認識。
final class AnalyzerRecognizer: LiveRecognizer, @unchecked Sendable {
    private let kind: RecognizerKind
    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var resultTask: Task<Void, Never>?
    private let lock = NSLock()

    init(kind: RecognizerKind) { self.kind = kind }

    func start(inputFormat: AVAudioFormat, onText: @escaping @Sendable (String, Bool) -> Void) async throws {
        let module: any SpeechModule
        switch kind {
        case .speechTranscriber:
            let t = SpeechTranscriber(locale: Japanese.locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
            resultTask = Task {
                do { for try await r in t.results { onText(String(r.text.characters), r.isFinal) } } catch {}
            }
            module = t
        case .dictationTranscriber:
            let t = DictationTranscriber(locale: Japanese.locale, contentHints: [], transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
            resultTask = Task {
                do { for try await r in t.results { onText(String(r.text.characters), r.isFinal) } } catch {}
            }
            module = t
        case .sfSpeechRecognizer:
            preconditionFailure("SFSpeechRecognizer は SFRecognizer を使う")
        }

        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module], considering: inputFormat) ?? inputFormat
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        lock.withLock {
            targetFormat = format
            converter = format == inputFormat ? nil : AVAudioConverter(from: inputFormat, to: format)
            continuation = cont
        }
        let analyzer = SpeechAnalyzer(modules: [module])
        self.analyzer = analyzer
        try await analyzer.start(inputSequence: stream)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let (cont, conv, fmt) = lock.withLock { (continuation, converter, targetFormat) }
        guard let cont else { return }
        guard let conv, let fmt else {
            cont.yield(AnalyzerInput(buffer: buffer))
            return
        }
        let ratio = fmt.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
        guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: capacity) else { return }
        nonisolated(unsafe) var consumed = false
        var error: NSError?
        conv.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        if error == nil, out.frameLength > 0 { cont.yield(AnalyzerInput(buffer: out)) }
    }

    func stop() async {
        let cont = lock.withLock { () -> AsyncStream<AnalyzerInput>.Continuation? in
            defer { continuation = nil }
            return continuation
        }
        cont?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        resultTask?.cancel()
        analyzer = nil
    }
}

/// 旧来の SFSpeechRecognizer（端末内モード優先）による認識。
final class SFRecognizer: LiveRecognizer, @unchecked Sendable {
    private let recognizer = SFSpeechRecognizer(locale: Japanese.locale)
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let lock = NSLock()

    func start(inputFormat: AVAudioFormat, onText: @escaping @Sendable (String, Bool) -> Void) async throws {
        let status = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        guard status == .authorized, let recognizer else { throw SpikeError.speechNotAuthorized }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        lock.withLock { request = req }
        task = recognizer.recognitionTask(with: req) { result, _ in
            guard let result else { return }
            onText(result.bestTranscription.formattedString, result.isFinal)
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock { request }?.append(buffer)
    }

    func stop() async {
        lock.withLock { request }?.endAudio()
        task?.finish()
        task = nil
    }
}

enum SpikeError: LocalizedError {
    case speechNotAuthorized
    case noRecognizer

    var errorDescription: String? {
        switch self {
        case .speechNotAuthorized: "音声認識が許可されていません（設定 > プライバシー）"
        case .noRecognizer: "日本語に対応した認識エンジンがありません"
        }
    }
}
