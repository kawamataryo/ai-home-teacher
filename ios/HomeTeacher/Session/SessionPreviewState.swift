import Foundation

/// 表示確認用に固定する画面の状態（起動引数 `-sessionPreview idle|listening|speaking`）。
enum SessionPreviewState: String, CaseIterable, Sendable {
    case idle
    case listening
    case speaking

    static func fromLaunchArguments(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> SessionPreviewState? {
        guard let index = arguments.firstIndex(of: "-sessionPreview"), index + 1 < arguments.count else { return nil }
        return SessionPreviewState(rawValue: arguments[index + 1])
    }
}
