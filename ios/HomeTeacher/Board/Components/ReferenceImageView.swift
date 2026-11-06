import SwiftUI
import UIKit

/// 黒板に貼った本物の写真（#116）。下に説明と、作者・ライセンスを書く。
struct ReferenceImageView: View {
    let image: ReferenceImage

    var body: some View {
        VStack(spacing: 14) {
            if let uiImage = UIImage(data: image.data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .padding(10)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 5)
                    .rotationEffect(.degrees(-0.8))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel(image.caption)
            }
            Text(image.caption)
                .font(Chalk.font(34, weight: .bold))
                .foregroundStyle(Chalk.yellow)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .multilineTextAlignment(.center)
                .chalkWriteIn(characters: image.caption.count)
            Text(image.credit)
                .font(.system(size: 16))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
