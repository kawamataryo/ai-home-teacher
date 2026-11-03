import Foundation
import Testing
import UIKit
@testable import HomeTeacher

struct ImageResizerTests {
    /// 指定したピクセル数の画像を作る（scale 1）。
    private func makeImage(width: CGFloat, height: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        }
    }

    private func pixelSize(of data: Data) throws -> (Int, Int) {
        let image = try #require(UIImage(data: data))
        let cg = try #require(image.cgImage)
        return (cg.width, cg.height)
    }

    @Test func 横長は長辺2048pxに縮める() throws {
        let data = try #require(ImageResizer.jpegData(from: makeImage(width: 4032, height: 3024)))
        let (w, h) = try pixelSize(of: data)
        #expect(w == 2048)
        #expect(h == 1536)
        #expect(Array(data.prefix(2)) == [0xFF, 0xD8])
    }

    @Test func 縦長も長辺で縮める() throws {
        let data = try #require(ImageResizer.jpegData(from: makeImage(width: 3000, height: 4000)))
        let (w, h) = try pixelSize(of: data)
        #expect(h == 2048)
        #expect(w == 1536)
    }

    @Test func 小さい画像は拡大しない() throws {
        let data = try #require(ImageResizer.jpegData(from: makeImage(width: 800, height: 600)))
        let (w, h) = try pixelSize(of: data)
        #expect((w, h) == (800, 600))
    }

    @Test func 端末の倍率がかかった画像もピクセルで数える() throws {
        // 2x の 1500pt×1000pt = 3000px×2000px
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1500, height: 1000), format: format).image { _ in }
        let data = try #require(ImageResizer.jpegData(from: image))
        let (w, h) = try pixelSize(of: data)
        #expect((w, h) == (2048, 1365))
    }

    @Test func 目標の大きさの計算() {
        #expect(ImageResizer.targetPixelSize(for: CGSize(width: 2048, height: 100)) == CGSize(width: 2048, height: 100))
        #expect(ImageResizer.targetPixelSize(for: CGSize(width: 4096, height: 4096)) == CGSize(width: 2048, height: 2048))
    }
}
