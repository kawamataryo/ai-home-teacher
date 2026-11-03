import Foundation

/// Worker / Claude につながらなかった理由（#66）。子どもには「ちょっと調子が悪いみたい」とだけ伝え、
/// 画面には保護者向けに何を直せばよいかを出す。
enum ConnectionProblem: Equatable, Sendable {
    /// Secrets.xcconfig がない（WORKER_BASE_URL / FAMILY_TOKEN が空）
    case notConfigured
    /// 家族トークンの誤り（401 / 403）
    case unauthorized
    /// インターネットにつながっていない
    case offline
    /// Worker / Claude のエラー（5xx・overloaded など）
    case server
    /// 返事が来ない・遅すぎる
    case timeout
    case other

    init(_ error: any Error) {
        switch error {
        case WorkerError.notConfigured:
            self = .notConfigured
        case WorkerError.http(let status, _) where status == 401 || status == 403:
            self = .unauthorized
        case WorkerError.http(let status, _) where status >= 500:
            self = .server
        case is TeacherBrainError:
            self = .server
        case is DeadlineExceeded, DecisionError.timeout:
            self = .timeout
        case let urlError as URLError:
            switch urlError.code {
            case .timedOut: self = .timeout
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
                 .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff:
                self = .offline
            default: self = .other
            }
        default:
            self = .other
        }
    }

    /// 保護者向けの案内（画面に小さく出す）
    var parentMessage: String {
        switch self {
        case .notConfigured:
            "Worker の設定がありません。Secrets.xcconfig に WORKER_BASE_URL と FAMILY_TOKEN を書いて、ビルドし直してください。今は端末の声だけで動いています。"
        case .unauthorized:
            "家族トークンが Worker と合っていません（401）。Secrets.xcconfig の FAMILY_TOKEN を、Worker の FAMILY_TOKEN と同じにしてビルドし直してください。"
        case .offline:
            "インターネットにつながっていません。Wi-Fi を確かめてください。"
        case .server:
            "先生のサーバー（Worker / Claude）の調子が悪いようです。少し待ってから話しかけてください。"
        case .timeout:
            "先生の返事に時間がかかっています。通信の状態を確かめてください。"
        case .other:
            "先生の返事を受け取れませんでした。通信の状態を確かめてください。"
        }
    }
}

/// `Deadline.run` が時間切れになった
struct DeadlineExceeded: Error, Equatable {}

/// 会話の時計（テストでは ManualClock）で時間を区切る。
enum Deadline {
    /// `operation` が `limit` までに終わらなければ止めて `DeadlineExceeded` を投げる
    @MainActor
    static func run<T: Sendable>(
        _ limit: Duration, clock: any ConversationClock, _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let work = Task { try await operation() }
        let gate = Gate<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.continuation = continuation
                gate.timer = clock.schedule(after: limit) {
                    work.cancel()
                    gate.resume(.failure(DeadlineExceeded()))
                }
                Task { @MainActor in
                    let result = await work.result
                    gate.resume(result)
                }
            }
        } onCancel: {
            work.cancel()
        }
    }

    @MainActor
    private final class Gate<T: Sendable> {
        var continuation: CheckedContinuation<T, any Error>?
        var timer: (any ScheduledAction)?

        func resume(_ result: Result<T, any Error>) {
            timer?.cancel()
            timer = nil
            guard let continuation else { return }
            self.continuation = nil
            continuation.resume(with: result)
        }
    }
}
