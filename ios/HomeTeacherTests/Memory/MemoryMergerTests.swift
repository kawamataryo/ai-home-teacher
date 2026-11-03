import Foundation
import Testing
@testable import HomeTeacher

struct MemoryMergerTests {
    private let t0 = Date(timeIntervalSince1970: 1_793_000_000)
    private var now: Date { t0.addingTimeInterval(86_400) }

    private func item(_ content: String, _ offset: TimeInterval = 0, _ category: MemoryCategory = .likes) -> MemoryRecord {
        MemoryRecord(category: category, content: content, updatedAt: t0.addingTimeInterval(offset))
    }

    private func merge(_ existing: [MemoryRecord], add: [String] = [], remove: [String] = [], cap: Int = 20) -> [MemoryRecord] {
        MemoryMerger.merge(existing: existing, change: .init(add: add, remove: remove), category: .likes, now: now, cap: cap)
    }

    @Test func 新しいものを足して新しい順に並べる() {
        let merged = merge([item("サッカー")], add: ["猫のミケ"])
        #expect(merged.map(\.content) == ["猫のミケ", "サッカー"])
        #expect(merged[0].updatedAt == now)
    }

    @Test func すでにある内容は重ねずに更新日時だけ新しくする() {
        let merged = merge([item("サッカー"), item("マイクラ", 10)], add: ["サッカー"])
        #expect(merged.map(\.content) == ["サッカー", "マイクラ"])
        #expect(merged[0].updatedAt == now)
    }

    @Test func 空白と大文字小文字と全角半角の違いは同じとみなす() {
        let merged = merge([item("Minecraft"), item("サッカー  クラブ")], add: ["ｍｉｎｅｃｒａｆｔ", " サッカー クラブ "])
        #expect(merged.count == 2)
        #expect(merged.allSatisfy { $0.updatedAt == now })
    }

    @Test func 消すものを先に消してから足す() {
        // 同じものを消して足すと、新しく入れ直したことになる
        let merged = merge([item("サッカー"), item("野球")], add: ["サッカー"], remove: ["サッカー", "やきゅう", " 野球 "])
        #expect(merged.map(\.content) == ["サッカー"])
        #expect(merged[0].updatedAt == now)
    }

    @Test func ない内容を消そうとしても何もしない() {
        let existing = [item("サッカー")]
        #expect(merge(existing, remove: ["テニス"]) == existing)
    }

    @Test func 空の内容は無視し長すぎる内容は500文字で切る() {
        let merged = merge([], add: ["", "   ", String(repeating: "あ", count: 600)])
        #expect(merged.count == 1)
        #expect(merged[0].content.count == 500)
    }

    @Test func 上限をこえたら古いものから捨てる() {
        let existing = (0..<20).map { item("好き\($0)", TimeInterval($0)) }
        let merged = merge(existing, add: ["新しい好き"])
        #expect(merged.count == 20)
        #expect(merged.first?.content == "新しい好き")
        #expect(!merged.contains { $0.content == "好き0" })
        #expect(merged.contains { $0.content == "好き1" })

        #expect(merge(existing, cap: 5).map(\.content) == ["好き19", "好き18", "好き17", "好き16", "好き15"])
    }

    @Test func ほかのカテゴリの記憶はまぜない() {
        let merged = merge([item("割合", 0, .weakPoints), item("サッカー")], add: ["割合"])
        #expect(merged.map(\.category) == [.likes, .likes])
        #expect(Set(merged.map(\.content)) == ["割合", "サッカー"])
    }
}
