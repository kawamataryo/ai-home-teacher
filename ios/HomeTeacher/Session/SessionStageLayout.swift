import CoreGraphics

/// セッション画面の「舞台」（先生と黒板の場所）を決める（#105）。
///
/// - 先生だけ（黒板に何も書いていない）：先生を大きく、黒板は横の小さな看板（使い方の案内を書く）
/// - 黒板（図を書いている）：黒板を大きく、先生は黒板の右下に重ねて立つ
///
/// 画面はこの四角に合わせて frame と offset を変えるだけにする。先生（RealityView）を作り直さないため、表示の木は切り替えない
struct SessionStageLayout: Equatable {
    enum Mode: Equatable {
        case teacher
        case board
    }

    /// 先生の枠の横と縦の比。カメラの写し方が決まっているので、枠の比を変えない（頭や足が切れる）
    static let teacherAspect: CGFloat = 0.8
    /// 先生の枠のうち、体が写っているところ（左右の余白を除いた幅の割合）
    static let teacherBodyWidth: CGFloat = 0.56
    /// 黒板の中身を描く大きさ（大きな黒板・小さな看板）。場所に合わせて縮め、比が違えば長い方に広げる
    static let boardDesignBase = CGSize(width: 1100, height: 860)
    static let signDesignBase = CGSize(width: 520, height: 330)

    let mode: Mode
    let board: CGRect
    let teacher: CGRect
    /// タイマーと状態のしるしを置く場所（左上を合わせる）
    let hud: CGRect
    /// 黒板の中身を描く大きさの基準
    let designBase: CGSize
    /// 先生の体が黒板に重なっている幅（右から）と高さ（下から）。pt
    let occlusion: CGSize

    init(size: CGSize, mode: Mode) {
        self.mode = mode
        let w = max(size.width, 1)
        let h = max(size.height, 1)
        let isWide = w >= h
        switch (mode, isWide) {
        case (.teacher, true):
            let th = h
            let tw = min(th * Self.teacherAspect, w * 0.6)
            let teacher = CGRect(x: min(w * 0.66 - tw / 2, w - tw), y: h - th, width: tw, height: th)
            let signW = min(w * 0.4, teacher.minX - w * 0.03)
            let signH = signW * 0.62
            board = CGRect(x: (teacher.minX - signW) / 2, y: h * 0.42 - signH / 2, width: signW, height: signH)
            self.teacher = teacher
            hud = CGRect(x: 0, y: 0, width: teacher.minX, height: board.minY)
            designBase = Self.signDesignBase
        case (.teacher, false):
            let th = h * 0.64
            let tw = min(th * Self.teacherAspect, w)
            teacher = CGRect(x: (w - tw) / 2, y: h - th, width: tw, height: th)
            let signW = w * 0.62
            let signH = min(signW * 0.62, teacher.minY - h * 0.04)
            board = CGRect(x: (w - signW) / 2, y: h * 0.02, width: signW, height: signH)
            hud = CGRect(x: 0, y: teacher.minY, width: teacher.minX, height: th)
            designBase = Self.signDesignBase
        case (.board, true):
            let th = h * 0.8
            let tw = th * Self.teacherAspect
            // 枠の右の余白ぶん、画面の右へはみ出させて体を右端に寄せる
            teacher = CGRect(x: w - tw * 0.86, y: h - th, width: tw, height: th)
            // 先生の体の半分くらいが黒板の右下に重なる
            let boardW = min(w, teacher.midX + tw * 0.08)
            board = CGRect(x: 0, y: 0, width: boardW, height: h - 10)
            hud = CGRect(x: boardW + 8, y: 0, width: max(w - boardW - 8, 0), height: teacher.minY + th * 0.12)
            designBase = Self.boardDesignBase
        case (.board, false):
            let th = h * 0.46
            let tw = th * Self.teacherAspect
            teacher = CGRect(x: w - tw * 0.9, y: h - th, width: tw, height: th)
            board = CGRect(x: 0, y: 0, width: w, height: h * 0.76)
            hud = CGRect(x: 0, y: board.maxY + 16, width: teacher.minX, height: h - board.maxY - 16)
            designBase = CGSize(width: Self.boardDesignBase.width, height: Self.boardDesignBase.width * 0.9)
        }
        let bodyLeft = teacher.midX - teacher.width * Self.teacherBodyWidth / 2
        // 先生の頭の上には少し余白がある（枠の上 1 割）
        let bodyTop = teacher.minY + teacher.height * 0.1
        occlusion = mode == .board
            ? CGSize(width: max(board.maxX - bodyLeft, 0), height: max(board.maxY - bodyTop, 0))
            : .zero
    }

    /// 黒板の中身を描く大きさ。`boardSize`（枠の内側）と同じ比にして、基準より小さくしない
    static func designSize(for boardSize: CGSize, base: CGSize) -> CGSize {
        guard boardSize.width > 0, boardSize.height > 0 else { return base }
        let scale = min(boardSize.width / base.width, boardSize.height / base.height)
        return CGSize(width: boardSize.width / scale, height: boardSize.height / scale)
    }
}
