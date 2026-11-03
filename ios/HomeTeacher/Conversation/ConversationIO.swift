import Foundation

/// 聞き取り側から届く出来事。実装は AudioEngine + SpeechAnalyzer / SpeechDetector（別 issue）。
enum SpeechInputEvent: Equatable, Sendable {
    /// 声を検出した（SpeechDetector）
    case voiceStarted
    /// 声が止まった（無音の始まり）
    case voiceEnded
    /// いま聞いている発話の書き起こし。途中経過も含め、毎回「発話全体の最新値」を送る
    case transcript(String)
}

/// 音声入力。テストではモックに差し替える。
@MainActor
protocol SpeechInput: AnyObject {
    var events: AsyncStream<SpeechInputEvent> { get }
    /// 「先生が話している間はマイクを止める」モードで使う
    func setMuted(_ muted: Bool)
}

/// 音声出力（TTS 再生）。テストではモックに差し替える。
@MainActor
protocol SpeechOutput: AnyObject {
    /// 1 文を再生し、再生し終わったら戻る
    func speak(_ text: String) async
}

/// 一度だけ予約した処理。取り消せる。
@MainActor
protocol ScheduledAction: AnyObject {
    func cancel()
}

/// 時刻と遅延実行。テストでは手で進める時計に差し替える。
@MainActor
protocol ConversationClock: AnyObject {
    var now: ContinuousClock.Instant { get }
    /// `delay` 後に `action` を MainActor で 1 回実行する
    func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void) -> any ScheduledAction
}

/// 本番用の時計。
@MainActor
final class SystemConversationClock: ConversationClock {
    var now: ContinuousClock.Instant { .now }

    func schedule(after delay: Duration, _ action: @escaping @MainActor () -> Void) -> any ScheduledAction {
        TaskAction(Task { @MainActor in
            // キャンセルされたら sleep が throw するので、action は呼ばれない
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled else { return }
            action()
        })
    }

    private final class TaskAction: ScheduledAction {
        private let task: Task<Void, Never>
        init(_ task: Task<Void, Never>) { self.task = task }
        func cancel() { task.cancel() }
    }
}
