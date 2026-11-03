import Foundation

/// 先生の返事の流れに、時間の見張りをはさむ（#66）。
///
/// - 1 文目が `fillerAfter` までに届かなければ `.filler` を流す（定型句でつなぐ）
/// - `giveUpAfter` の間なにも届かなければ（最初の 1 文目までも、途中で止まったときも）`DeadlineExceeded` で終える。
///   元の流れは止める（TeacherBrain のストリームも止まる）
enum ReplyWatchdog {
    enum Event: Equatable, Sendable {
        case output(TeacherOutput)
        /// 1 文目が遅い。定型句でつなぐ
        case filler
    }

    @MainActor
    static func watch(
        _ source: AsyncThrowingStream<TeacherOutput, Error>,
        clock: any ConversationClock,
        fillerAfter: Duration?,
        giveUpAfter: Duration
    ) -> AsyncThrowingStream<Event, Error> {
        let (stream, continuation) = AsyncThrowingStream<Event, Error>.makeStream()
        let timers = Timers()
        func armGiveUp() {
            timers.giveUp?.cancel()
            timers.giveUp = clock.schedule(after: giveUpAfter) {
                timers.cancelAll()
                continuation.finish(throwing: DeadlineExceeded())
            }
        }
        if let fillerAfter {
            timers.filler = clock.schedule(after: fillerAfter) {
                timers.filler = nil
                continuation.yield(.filler)
            }
        }
        armGiveUp()
        timers.forward = Task { @MainActor in
            do {
                for try await output in source {
                    if case .sentence = output {
                        timers.filler?.cancel()
                        timers.filler = nil
                    }
                    armGiveUp()
                    continuation.yield(.output(output))
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
            timers.cancelAll()
        }
        continuation.onTermination = { _ in
            Task { @MainActor in timers.cancelAll() }
        }
        return stream
    }

    @MainActor
    private final class Timers {
        var filler: (any ScheduledAction)?
        var giveUp: (any ScheduledAction)?
        var forward: Task<Void, Never>?

        func cancelAll() {
            filler?.cancel()
            giveUp?.cancel()
            forward?.cancel()
            filler = nil
            giveUp = nil
            forward = nil
        }
    }
}
