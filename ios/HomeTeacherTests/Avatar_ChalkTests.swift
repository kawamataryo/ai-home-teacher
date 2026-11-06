import CoreGraphics
import Testing
@testable import HomeTeacher

/// チョークの先生（#127）
struct ChalkLayoutTests {
    private static let sizes = [CGSize(width: 1194, height: 834), CGSize(width: 834, height: 1194), CGSize(width: 1668, height: 2420)]

    @Test(arguments: sizes)
    func 黒板を大きくしたらキャラは黒板の中にいて図は重ならない(size: CGSize) {
        let layout = SessionStageLayout(size: size, mode: .board, livesOnBoard: true)
        // 黒板の枠の中に収まる
        #expect(layout.board.contains(layout.teacher))
        // 図は occlusion の分をよけて書く：キャラの右下の四角をすべて含む
        #expect(layout.occlusion.width >= layout.teacher.width)
        #expect(layout.occlusion.height >= layout.teacher.height)
        #expect(layout.board.maxX - layout.occlusion.width <= layout.teacher.minX)
        #expect(layout.board.maxY - layout.occlusion.height <= layout.teacher.minY)
        let scale: CGFloat = 1
        let insets = SessionContent.occludedInsets(layout.occlusion, board: layout.board.size, scale: scale)
        #expect(insets.trailing >= layout.occlusion.width || insets.bottom >= layout.occlusion.height)
    }

    @Test(arguments: sizes)
    func 黒板に書いていないときは今と同じ場所(size: CGSize) {
        let normal = SessionStageLayout(size: size, mode: .teacher)
        let chalk = SessionStageLayout(size: size, mode: .teacher, livesOnBoard: true)
        #expect(normal == chalk)
    }

    @Test(arguments: sizes)
    func ふつうのキャラの黒板の配置は変わらない(size: CGSize) {
        let a = SessionStageLayout(size: size, mode: .board)
        let b = SessionStageLayout(size: size, mode: .board, livesOnBoard: false)
        #expect(a == b)
        #expect(!CharacterLook.haru.livesOnBoard)
        #expect(CharacterLook(kind: .chalk).livesOnBoard)
    }
}

struct ChalkFaceTests {
    @Test(arguments: AvatarState.allCases)
    func 線が枠の中に収まる(state: AvatarState) {
        // 手を上げても枠（320×400 の中心基準）の外に切れない
        for t in stride(from: 0.0, to: 7, by: 0.4) {
            let pose = PaperPose.make(state: state, timeInState: t, time: t)
            for pointing in [false, true] {
                for stroke in ChalkFace.strokes(pose: pose, mouth: .a, pointing: pointing) {
                    let box = stroke.path.boundingRect
                    #expect(box.minX >= -160 && box.maxX <= 160, "\(state) t=\(t) \(box)")
                    #expect(box.minY >= -200 && box.maxY <= 200, "\(state) t=\(t) \(box)")
                }
            }
        }
    }

    @Test func 状態と口で線が変わる() {
        let pose = PaperPose.make(state: .idle, timeInState: 1, time: 1)
        let closed = ChalkFace.strokes(pose: pose, mouth: .closed, pointing: false)
        let open = ChalkFace.strokes(pose: pose, mouth: .a, pointing: false)
        #expect(closed.map(\.path) != open.map(\.path))
        var happy = pose
        happy.eyes = .happy
        #expect(ChalkFace.strokes(pose: happy, mouth: .closed, pointing: false).map(\.path) != closed.map(\.path))
        #expect(ChalkFace.strokes(pose: pose, mouth: .closed, pointing: true).map(\.path) != closed.map(\.path))
        #expect(closed.count == ChalkFace.strokeCount)
    }
}

