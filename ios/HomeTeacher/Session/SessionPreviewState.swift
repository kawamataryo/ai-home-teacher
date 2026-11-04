import Foundation

/// 表示確認用に固定する画面の状態（起動引数 `-sessionPreview idle|listening|speaking|praise|encourage|teacher|board|tour`）。
enum SessionPreviewState: String, CaseIterable, Sendable {
    case idle
    case listening
    case speaking
    /// 自分で解けて、先生がほめている（#73）
    case praise
    /// 2回つまずいて、先生が励ましている（#73）
    case encourage
    /// セッション中で、黒板に何も書いていない（先生だけ。#105）
    case teacher
    /// 黒板に図を書いて話している。図は `-previewBoard <種類>`（#105）
    case board
    /// 先生だけ → 黒板 → 図の差し替え → しまう、をくり返す（動画の確認用。#105）
    case tour

    static func fromLaunchArguments(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> SessionPreviewState? {
        guard let value = argument(after: "-sessionPreview", in: arguments) else { return nil }
        return SessionPreviewState(rawValue: value)
    }

    /// `-previewBoard` で選ぶ図。部品の名前（`step_cards` など）、`svg`、`text`（読めない入力の代わり）。既定は手順カード
    static func previewBoard(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> BoardContent {
        board(named: argument(after: "-previewBoard", in: arguments) ?? BoardComponent.Kind.stepCards.rawValue)
    }

    static func board(named name: String) -> BoardContent {
        switch name {
        case "svg": return BoardSamples.svgContent
        case "text":
            return BoardTools.content(toolName: BoardTools.showBoardName, input: Data(BoardSamples.brokenJSON.utf8))
        default:
            return BoardSamples.content(BoardComponent.Kind(rawValue: name) ?? .stepCards)
        }
    }

    private static func argument(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}
