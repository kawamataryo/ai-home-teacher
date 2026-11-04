import CoreGraphics
import SwiftUI
import Testing
@testable import HomeTeacher

/// 黒板を出しておくか、しまうかの規則（#105）
struct BoardStageTests {
    private func finish(_ stage: inout BoardStage, showedBoard: Bool, pace: BoardReveal.Pace?) -> Bool {
        stage.replyFinished(showedBoard: showedBoard, pace: pace)
    }

    @Test func 会話の図は図を使わない返事が2回続いたらしまう() {
        var stage = BoardStage()
        stage.boardPresented()
        #expect(!finish(&stage, showedBoard: true, pace: .sentence))
        #expect(!finish(&stage, showedBoard: false, pace: .sentence))
        #expect(finish(&stage, showedBoard: false, pace: .sentence))
    }

    @Test func 図を出し直したら数え直す() {
        var stage = BoardStage()
        #expect(!finish(&stage, showedBoard: false, pace: .sentence))
        stage.boardPresented()
        #expect(!finish(&stage, showedBoard: true, pace: .sentence))
        #expect(!finish(&stage, showedBoard: false, pace: .sentence))
    }

    @Test func 写真の分析の図は返事の回数ではしまわない() {
        var stage = BoardStage()
        for _ in 0..<5 {
            #expect(!finish(&stage, showedBoard: false, pace: .hintStage))
        }
    }

    @Test func 黒板に何もなければしまわない() {
        var stage = BoardStage()
        #expect(!finish(&stage, showedBoard: false, pace: nil))
        #expect(!finish(&stage, showedBoard: false, pace: nil))
    }

    @Test func 休憩のあいだ預かるのは解いている途中の問題の図だけ() {
        #expect(BoardStage.keepsThroughBreak(.hintStage))
        #expect(!BoardStage.keepsThroughBreak(.sentence))
        #expect(!BoardStage.keepsThroughBreak(nil))
    }
}

/// 先生と黒板の場所（#105）
struct SessionStageLayoutTests {
    static let landscape = CGSize(width: 1146, height: 600)
    static let portrait = CGSize(width: 786, height: 960)

    @Test(arguments: [landscape, portrait])
    func 先生の枠の比はどちらの見せ方でも変えない(_ size: CGSize) {
        for mode in [SessionStageLayout.Mode.teacher, .board] {
            let teacher = SessionStageLayout(size: size, mode: mode).teacher
            #expect(abs(teacher.width / teacher.height - SessionStageLayout.teacherAspect) < 0.001)
        }
    }

    @Test(arguments: [landscape, portrait])
    func 書くときは黒板が大きくなり先生は小さく右下に重なる(_ size: CGSize) {
        let teacherOnly = SessionStageLayout(size: size, mode: .teacher)
        let board = SessionStageLayout(size: size, mode: .board)
        #expect(board.board.width * board.board.height > teacherOnly.board.width * teacherOnly.board.height * 3)
        #expect(board.teacher.height < teacherOnly.teacher.height)
        // 右下にいて、黒板に重なる
        #expect(board.teacher.midX > size.width * 0.8)
        #expect(abs(board.teacher.maxY - size.height) < 0.5)
        #expect(board.board.intersects(board.teacher))
        #expect(board.occlusion.width > 0 && board.occlusion.height > 0)
        // 黒板と先生の体は舞台からはみ出さない（枠の左右の余白は画面の外に出てよい）
        let stage = CGRect(origin: .zero, size: size)
        let bodyWidth = board.teacher.width * SessionStageLayout.teacherBodyWidth
        let body = CGRect(x: board.teacher.midX - bodyWidth / 2, y: board.teacher.minY, width: bodyWidth, height: board.teacher.height)
        #expect(stage.contains(board.board) && stage.contains(body))
    }

    @Test(arguments: [landscape, portrait])
    func 先生だけのときは看板が先生に重ならない(_ size: CGSize) {
        let layout = SessionStageLayout(size: size, mode: .teacher)
        #expect(!layout.board.intersects(layout.teacher))
        #expect(layout.occlusion == .zero)
        #expect(CGRect(origin: .zero, size: size).contains(layout.board))
    }

    @Test func 中身を描く大きさは場所と同じ比で基準より小さくしない() {
        let base = SessionStageLayout.boardDesignBase
        for size in [CGSize(width: 960, height: 590), CGSize(width: 760, height: 700), CGSize(width: 300, height: 200)] {
            let design = SessionStageLayout.designSize(for: size, base: base)
            #expect(design.width >= base.width - 0.01 && design.height >= base.height - 0.01)
            #expect(abs(design.width / design.height - size.width / size.height) < 0.001)
        }
    }

    @Test func 先生が重なるところは減る面積が小さい方を空ける() {
        // 横長の黒板の右下に縦長の先生：右を空ける
        let wide = SessionContent.occludedInsets(CGSize(width: 100, height: 300), board: CGSize(width: 900, height: 600), scale: 0.5)
        #expect(wide.trailing == 224 && wide.bottom == 0)
        // 縦置き：下を空ける
        let tall = SessionContent.occludedInsets(CGSize(width: 300, height: 80), board: CGSize(width: 780, height: 700), scale: 0.5)
        #expect(tall.bottom == 184 && tall.trailing == 0)
        #expect(SessionContent.occludedInsets(.zero, board: CGSize(width: 900, height: 600), scale: 0.5) == EdgeInsets())
    }
}
