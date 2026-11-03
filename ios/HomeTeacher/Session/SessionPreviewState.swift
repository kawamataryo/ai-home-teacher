import Foundation

/// 表示確認用に固定する画面の状態（起動引数 `-sessionPreview idle|listening|speaking|praise|encourage`）。
enum SessionPreviewState: String, CaseIterable, Sendable {
    case idle
    case listening
    case speaking
    /// 自分で解けて、先生がほめている（#73）
    case praise
    /// 2回つまずいて、先生が励ましている（#73）
    case encourage

    static func fromLaunchArguments(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> SessionPreviewState? {
        guard let index = arguments.firstIndex(of: "-sessionPreview"), index + 1 < arguments.count else { return nil }
        return SessionPreviewState(rawValue: arguments[index + 1])
    }
}
