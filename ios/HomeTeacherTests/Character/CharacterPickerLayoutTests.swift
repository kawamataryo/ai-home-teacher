import CoreGraphics
import Testing
@testable import HomeTeacher

struct CharacterPickerLayoutTests {
    private static let sizes = [
        CGSize(width: 834, height: 1170), CGSize(width: 1194, height: 810),
        CGSize(width: 768, height: 1000), CGSize(width: 1024, height: 744),
        CGSize(width: 1024, height: 1342), CGSize(width: 1366, height: 1000),
    ]

    @Test(arguments: sizes)
    func はみ出さず重ならない(size: CGSize) {
        let layout = CharacterPickerLayout(size: size, count: 8)
        let screen = CGRect(origin: .zero, size: size)
        var seats: [CGRect] = []
        for index in 0..<8 {
            let seat = layout.seat(index)
            #expect(screen.contains(seat), "\(index) \(seat)")
            #expect(layout.figure(index).minY >= seat.minY - 0.5)
            #expect(!layout.figure(index).intersects(layout.tag(index)))
            for other in seats { #expect(!other.intersects(seat)) }
            seats.append(seat)
            #expect(!seat.intersects(layout.stage))
        }
        #expect(screen.contains(layout.stage))
        #expect(!layout.hero.intersects(layout.bubble))
        #expect(!layout.hero.intersects(layout.plate))
        #expect(!layout.plate.intersects(layout.button))
    }

    @Test(arguments: sizes)
    func 舞台のキャラは席より大きく席でも小さすぎない(size: CGSize) {
        let layout = CharacterPickerLayout(size: size, count: 8)
        #expect(layout.hero.width >= 280, "\(layout.hero)")
        #expect(layout.figure(0).width >= 110, "\(layout.figure(0))")
        #expect(layout.hero.width > layout.figure(0).width * 1.5)
    }

    @Test func 人数が少なくても席が作れる() {
        for count in 1...8 {
            let layout = CharacterPickerLayout(size: CGSize(width: 1194, height: 810), count: count)
            #expect(layout.columns >= 1)
            #expect(layout.rows * layout.columns >= count)
        }
    }
}
