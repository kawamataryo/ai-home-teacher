import Foundation
import Network
import os

/// ネットワークにつながったことを知らせる口。テストではモックを渡す。
protocol ConnectivityMonitoring: Sendable {
    /// つながっていない状態からつながったときに1回ずつ値が流れる。
    func connectivityRestored() -> AsyncStream<Void>
}

/// NWPathMonitor を使う本番用の実装。
final class NWPathConnectivityMonitor: ConnectivityMonitoring, Sendable {
    private let queue = DispatchQueue(label: "HomeTeacher.ConnectivityMonitor")

    func connectivityRestored() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let monitor = NWPathMonitor()
            // 最初の通知は「今の状態」なので、それ自体では流さない
            let wasSatisfied = OSAllocatedUnfairLock<Bool?>(initialState: nil)
            monitor.pathUpdateHandler = { path in
                let isSatisfied = path.status == .satisfied
                let restored = wasSatisfied.withLock { previous in
                    defer { previous = isSatisfied }
                    return previous == false && isSatisfied
                }
                if restored { continuation.yield() }
            }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: queue)
        }
    }
}
