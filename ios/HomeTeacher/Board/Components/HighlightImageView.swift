import SwiftUI

/// 撮影した写真の上に、注目してほしい場所の囲みを出す。
struct HighlightImageView: View {
    let model: HighlightImage
    @Environment(\.boardImageProvider) private var provider
    @Environment(\.boardAnimated) private var animated
    @State private var pulsing = false

    var body: some View {
        if let image = provider.image(model.imageId) {
            GeometryReader { geo in
                let frame = Self.fittedRect(image: image.size, in: geo.size)
                ZStack(alignment: .topLeading) {
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: frame.width, height: frame.height)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .offset(x: frame.minX, y: frame.minY)
                    ForEach(Array(model.regions.enumerated()), id: \.offset) { _, region in
                        let r = Self.regionRect(region, in: frame)
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Chalk.yellow, lineWidth: 5)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Chalk.yellow.opacity(0.12)))
                            .frame(width: r.width, height: r.height)
                            .scaleEffect(pulsing ? 1.03 : 1)
                            .offset(x: r.minX, y: r.minY)
                        Text(region.label)
                            .font(Chalk.font(24, weight: .bold))
                            .foregroundStyle(Chalk.boardDeep)
                            .padding(.horizontal, 12).padding(.vertical, 4)
                            .background(Capsule().fill(Chalk.yellow))
                            .fixedSize()
                            .offset(x: r.minX, y: Swift.max(r.minY - 40, frame.minY))
                    }
                }
            }
            .task {
                guard animated else { return }
                withAnimation(.easeInOut(duration: 0.8).repeatCount(4, autoreverses: true)) { pulsing = true }
                try? await Task.sleep(for: .seconds(3.2))
                pulsing = false
            }
        } else {
            // 写真が無いときは、囲みの言葉だけ出す
            VStack(alignment: .leading, spacing: 14) {
                Label("写真が見つからないよ", systemImage: "photo")
                    .font(Chalk.font(26))
                    .foregroundStyle(Chalk.faint)
                ForEach(Array(model.regions.enumerated()), id: \.offset) { _, region in
                    Text("・" + region.label).font(Chalk.font(30, weight: .bold)).foregroundStyle(Chalk.yellow)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// 写真を縦横比を保って枠に収めたときの位置。
    static func fittedRect(image: CGSize, in container: CGSize) -> CGRect {
        guard image.width > 0, image.height > 0, container.width > 0, container.height > 0 else { return .zero }
        let s = Swift.min(container.width / image.width, container.height / image.height)
        let size = CGSize(width: image.width * s, height: image.height * s)
        return CGRect(origin: CGPoint(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2), size: size)
    }

    /// 0〜1 の割合を、写真の上の位置にする。はみ出しは写真の中に収める。
    static func regionRect(_ r: HighlightImage.Region, in frame: CGRect) -> CGRect {
        func clamp(_ v: Double) -> CGFloat { v.isFinite ? CGFloat(Swift.min(Swift.max(v, 0), 1)) : 0 }
        let x = clamp(r.x), y = clamp(r.y)
        let w = Swift.min(clamp(r.width), 1 - x), h = Swift.min(clamp(r.height), 1 - y)
        return CGRect(x: frame.minX + x * frame.width, y: frame.minY + y * frame.height,
                      width: w * frame.width, height: h * frame.height)
    }
}
