import SwiftUI
import UIKit

/// 黒板の色と文字。チョークの色は白・黄・桃・水色の4色に絞る。
enum Chalk {
    static let board = Color(red: 0.16, green: 0.29, blue: 0.23)
    static let boardDeep = Color(red: 0.12, green: 0.23, blue: 0.18)
    static let frame = Color(red: 0.55, green: 0.38, blue: 0.22)
    static let frameDeep = Color(red: 0.40, green: 0.26, blue: 0.14)
    static let white = Color(white: 0.96)
    static let yellow = Color(red: 1.0, green: 0.88, blue: 0.40)
    static let pink = Color(red: 1.0, green: 0.62, blue: 0.70)
    static let blue = Color(red: 0.55, green: 0.82, blue: 1.0)
    static let faint = Color.white.opacity(0.35)

    static func font(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    /// 数を黒板に書く形にする（1.0 → 1、0.25 → 0.25）。
    static func number(_ v: Double) -> String {
        guard v.isFinite else { return "?" }
        if v == v.rounded(), abs(v) < 1e12 { return String(Int64(v)) }
        return String(format: "%.4g", v)
    }
}

/// 写真 ID から画像を引く（撮影画像は ConversationController 側が持つ）。
struct BoardImageProvider: Sendable {
    let image: @MainActor @Sendable (String) -> UIImage?
    static let none = BoardImageProvider { _ in nil }
}

extension EnvironmentValues {
    /// false にすると、登場アニメーションをせず最初から全部出す（スクリーンショット用）。
    @Entry var boardAnimated: Bool = true
    @Entry var boardImageProvider: BoardImageProvider = .none
}
