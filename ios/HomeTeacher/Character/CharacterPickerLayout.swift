import CoreGraphics

/// 選ぶ画面の配置。前の舞台に 1 人立ち、ほかのキャラは自分の席で待つ。
/// 横向きは舞台が左、席が右。縦向きは舞台が上、席が下。
/// キャラの 3D は作り直さず、席と舞台の間を動かすので、位置を 1 か所で計算する。
struct CharacterPickerLayout {
    static let margin: CGFloat = 24
    static let headerHeight: CGFloat = 56
    static let gap: CGFloat = 12
    /// 席の名札の高さ（名前と「いまの先生」）
    static let tagHeight: CGFloat = 50
    static let hintHeight: CGFloat = 30

    let size: CGSize
    let count: Int

    var isWide: Bool { size.width > size.height }

    private var content: CGRect {
        CGRect(
            x: Self.margin, y: Self.headerHeight + Self.margin / 2,
            width: max(0, size.width - Self.margin * 2),
            height: max(0, size.height - Self.headerHeight - Self.margin)
        )
    }

    /// 舞台全体（吹き出し・キャラ・名前・決めるボタン）
    var stage: CGRect {
        if isWide {
            return CGRect(x: content.minX, y: content.minY, width: content.width * 0.56, height: content.height)
        }
        return CGRect(x: content.minX, y: content.minY, width: content.width, height: content.height * 0.58)
    }

    var header: CGRect { CGRect(x: Self.margin, y: Self.margin / 2, width: max(0, size.width - Self.margin * 2), height: Self.headerHeight) }

    var bubble: CGRect { CGRect(x: stage.minX, y: stage.minY, width: stage.width, height: 112) }

    var button: CGRect {
        let width = min(stage.width, 480)
        return CGRect(x: stage.midX - width / 2, y: stage.maxY - 68, width: width, height: 68)
    }

    var plate: CGRect { CGRect(x: stage.minX, y: button.minY - 66, width: stage.width, height: 58) }

    var hero: CGRect {
        let top = bubble.maxY + 4
        let side = max(0, min(plate.minY - top, stage.width))
        return CGRect(x: stage.midX - side / 2, y: top, width: side, height: side)
    }

    /// 席の並ぶ場所（上に「さわると…」の案内）
    var roster: CGRect {
        if isWide {
            let x = stage.maxX + Self.margin
            return CGRect(x: x, y: content.minY, width: max(0, content.maxX - x), height: content.height)
        }
        let y = stage.maxY + Self.gap
        return CGRect(x: content.minX, y: y, width: content.width, height: max(0, content.maxY - y))
    }

    var hint: CGRect { CGRect(x: roster.minX, y: roster.minY, width: roster.width, height: Self.hintHeight) }

    private var seatArea: CGRect {
        CGRect(x: roster.minX, y: hint.maxY, width: roster.width, height: max(0, roster.height - Self.hintHeight))
    }

    /// キャラがいちばん大きく見える列の数
    var columns: Int {
        guard count > 0 else { return 1 }
        return (1...max(1, min(count, 4))).max { figureSide(columns: $0) < figureSide(columns: $1) } ?? 1
    }

    var rows: Int { max(1, (count + columns - 1) / columns) }

    private func figureSide(columns: Int) -> CGFloat {
        let rows = max(1, (count + columns - 1) / columns)
        let width = (seatArea.width - Self.gap * CGFloat(columns - 1)) / CGFloat(columns)
        let height = (seatArea.height - Self.gap * CGFloat(rows - 1)) / CGFloat(rows)
        return min(width, height - Self.tagHeight)
    }

    /// `index` 番めの席（キャラと名札）
    func seat(_ index: Int) -> CGRect {
        let width = (seatArea.width - Self.gap * CGFloat(columns - 1)) / CGFloat(columns)
        let height = (seatArea.height - Self.gap * CGFloat(rows - 1)) / CGFloat(rows)
        return CGRect(
            x: seatArea.minX + CGFloat(index % columns) * (width + Self.gap),
            y: seatArea.minY + CGFloat(index / columns) * (height + Self.gap),
            width: width, height: height
        )
    }

    /// 席でキャラが立つ場所
    func figure(_ index: Int) -> CGRect {
        let seat = seat(index)
        let side = max(0, min(seat.width, seat.height - Self.tagHeight))
        return CGRect(x: seat.midX - side / 2, y: seat.maxY - Self.tagHeight - side, width: side, height: side)
    }

    /// キャラを置く枠。3D の表示には周りに余白があるので、色の丸に対して少し大きく置く。
    /// 2D は枠いっぱいに描くので、名前や吹き出しにかからないように小さく置く
    static func figureFrame(_ rect: CGRect, kind: CharacterLook.Kind) -> CGRect {
        switch kind {
        case .voxel, .rigged: rect.insetBy(dx: -rect.width * 0.14, dy: -rect.height * 0.14)
        case .paper, .chalk: rect
        }
    }

    /// 席の名札
    func tag(_ index: Int) -> CGRect {
        let seat = seat(index)
        return CGRect(x: seat.minX, y: seat.maxY - Self.tagHeight, width: seat.width, height: Self.tagHeight)
    }
}
