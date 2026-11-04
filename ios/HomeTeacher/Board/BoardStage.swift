import Foundation

/// 黒板を出しておくか、しまって先生だけにするかを決める（#105）。
///
/// - 図を出したら黒板を大きくする（画面は `board != nil` を見る）
/// - 会話の途中の図（`.sentence`）は、図を使わない返事が `quietRepliesBeforePutAway` 回続いたら話題が移ったとみなしてしまう
/// - 写真の分析の図（`.hintStage`）は解いている途中の問題なので、返事の回数ではしまわない
/// - 休憩に入ったらしまう。解いている途中の問題の図は預かっておき、休憩が終わったら出し直す
struct BoardStage: Equatable, Sendable {
    static let quietRepliesBeforePutAway = 2

    /// 図を出してから、図を使わずに終わった返事の数
    private(set) var quietReplies = 0

    /// 図を出した
    mutating func boardPresented() {
        quietReplies = 0
    }

    /// 返事を最後まで話した。しまうなら true
    ///
    /// - Parameters:
    ///   - showedBoard: この返事で図を出したか
    ///   - pace: いま黒板に出ている図の見せ方。nil なら黒板に何もない
    mutating func replyFinished(showedBoard: Bool, pace: BoardReveal.Pace?) -> Bool {
        guard !showedBoard, pace == .sentence else {
            quietReplies = 0
            return false
        }
        quietReplies += 1
        guard quietReplies >= Self.quietRepliesBeforePutAway else { return false }
        quietReplies = 0
        return true
    }

    mutating func reset() {
        quietReplies = 0
    }

    /// 休憩のあいだ預かる図か（解いている途中の問題の図だけ）
    static func keepsThroughBreak(_ pace: BoardReveal.Pace?) -> Bool {
        pace == .hintStage
    }
}
