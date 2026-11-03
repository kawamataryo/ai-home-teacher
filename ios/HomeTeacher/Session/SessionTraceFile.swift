import Foundation

/// 起動引数 `-traceToFile` のとき、セッションの記録（trace）を Documents/session-trace.txt に追記する。
/// 実機で人が試したときの様子を、あとから Mac で読むため（`xcrun devicectl device copy from`）。
/// 書くのは先生と子どもの発話の文字と判定の結果だけで、音声や写真は書かない。
final class SessionTraceFile: @unchecked Sendable {
    static let fileName = "session-trace.txt"

    private let url: URL
    private let lock = NSLock()
    private let formatter = ISO8601DateFormatter()

    init(url: URL) {
        self.url = url
    }

    static func fromLaunchArguments(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> SessionTraceFile? {
        guard arguments.contains("-traceToFile"),
              let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        else { return nil }
        return SessionTraceFile(url: dir.appending(path: fileName))
    }

    func append(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)\n"
        lock.withLock {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}
