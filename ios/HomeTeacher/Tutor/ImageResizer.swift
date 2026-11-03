import UIKit

/// 撮影した画像を、送る前に長辺 2048px の JPEG にする（spec §3②）。
enum ImageResizer {
    static let maxLongEdge: CGFloat = 2048
    static let defaultQuality: CGFloat = 0.8

    /// 長辺が `maxLongEdge` を超えるときだけ縮める（拡大はしない）。ピクセル数で数える。
    static func targetPixelSize(for pixelSize: CGSize, maxLongEdge: CGFloat = maxLongEdge) -> CGSize {
        let longEdge = max(pixelSize.width, pixelSize.height)
        guard longEdge > maxLongEdge, longEdge > 0 else { return pixelSize }
        let scale = maxLongEdge / longEdge
        return CGSize(width: (pixelSize.width * scale).rounded(), height: (pixelSize.height * scale).rounded())
    }

    /// 縮めた画像。向き（imageOrientation）は描き直すときに反映される。
    static func resized(_ image: UIImage, maxLongEdge: CGFloat = maxLongEdge) -> UIImage {
        let pixelSize = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let target = targetPixelSize(for: pixelSize, maxLongEdge: maxLongEdge)
        let format = UIGraphicsImageRendererFormat()
        // 端末の倍率（iPad は 2x）を掛けないよう、1pt = 1px で描く
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    /// 縮めて JPEG にする。
    static func jpegData(
        from image: UIImage,
        maxLongEdge: CGFloat = maxLongEdge,
        compressionQuality: CGFloat = defaultQuality
    ) -> Data? {
        resized(image, maxLongEdge: maxLongEdge).jpegData(compressionQuality: compressionQuality)
    }
}
