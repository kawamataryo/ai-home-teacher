import Foundation

/// 通信エラーと 5xx のときの、指数バックオフでのやり直し。4xx はやり直さない（送り直しても同じ結果になる）。
struct RetryPolicy: Sendable {
    /// 最初の1回を含めた回数。
    var maxAttempts: Int = 4
    var baseDelay: Duration = .seconds(1)
    var multiplier: Double = 2
    var maxDelay: Duration = .seconds(30)

    static let `default` = RetryPolicy()

    /// attempt 回目（1始まり）が失敗したあとに待つ時間。1秒 → 2秒 → 4秒 …（上限 maxDelay）。
    func delay(afterAttempt attempt: Int) -> Duration {
        let factor = pow(multiplier, Double(max(0, attempt - 1)))
        return min(baseDelay * factor, maxDelay)
    }

    /// やり直す価値のあるエラーか。
    static func isRetryable(_ error: any Error) -> Bool {
        switch error {
        case WorkerError.http(let status, _):
            return (500..<600).contains(status)
        case let error as URLError:
            return transientCodes.contains(error.code)
        default:
            return false
        }
    }

    /// つながっていない・途中で切れた・遅すぎたなど、時間をおけば直りそうなもの。
    static func isNetworkError(_ error: any Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return transientCodes.contains(error.code)
    }

    private static let transientCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost,
        .cannotFindHost, .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed,
        .callIsActive, .secureConnectionFailed,
    ]

    /// `operation` をやり直しながら実行する。やり直せないエラーや、回数を使い切ったら最後のエラーを投げる。
    func run<T: Sendable>(
        sleep: @Sendable (Duration) async throws -> Void,
        _ operation: () async throws -> T
    ) async throws -> T {
        var attempt = 1
        while true {
            do {
                return try await operation()
            } catch {
                guard attempt < maxAttempts, Self.isRetryable(error), !Task.isCancelled else { throw error }
                try await sleep(delay(afterAttempt: attempt))
                attempt += 1
            }
        }
    }
}
