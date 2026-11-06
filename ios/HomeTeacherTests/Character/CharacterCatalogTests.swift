import Foundation
import Testing
@testable import HomeTeacher

struct CharacterCatalogTests {
    private static let other = TeacherCharacter(
        id: "other", name: "ほか", honorific: "先生", relation: .teacher, roleLine: "付き添います。", roleNoun: "家庭教師", nudgeTone: "明るく", selectable: true
    )

    private func makeDefaults() -> UserDefaults {
        let name = "CharacterCatalogTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func 同梱の一覧に今の先生があり定義と一致する() {
        let catalog = CharacterCatalog()
        #expect(catalog.defaultCharacter == .haru)
        #expect(catalog.character(id: "haru").callName == "ハル先生")
        #expect(Set(catalog.characters.map(\.id)).count == catalog.characters.count)
    }

    @Test func 未選択なら既定の先生() {
        #expect(CharacterCatalog().character(id: nil) == .haru)
    }

    @Test func 知らないキャラなら既定の先生() {
        #expect(CharacterCatalog().character(id: "いなくなったキャラ") == .haru)
        #expect(CharacterCatalog().character(id: "") == .haru)
    }

    @Test func 一覧を読めなくても既定の先生になる() {
        let catalog = CharacterCatalog(bundle: Bundle(for: EmptyBundleMarker.self))
        #expect(catalog.characters == [.haru])
    }

    @Test func 一覧に既定の先生がなくても先頭に足す() {
        let catalog = CharacterCatalog(characters: [Self.other])
        #expect(catalog.characters.map(\.id) == ["haru", "other"])
    }

    @MainActor @Test func 選択は保存され再起動後も残る() {
        let defaults = makeDefaults()
        let other = Self.other
        let catalog = CharacterCatalog(characters: [.haru, other])
        let first = SessionPreferences(defaults: defaults, catalog: catalog)
        #expect(first.selectedCharacter == .haru)
        first.characterID = "other"
        #expect(first.selectedCharacter == other)

        let reopened = SessionPreferences(defaults: defaults, catalog: catalog)
        #expect(reopened.characterID == "other")
        #expect(reopened.selectedCharacter == other)
    }

    @MainActor @Test func 保存された選択が知らないキャラなら既定の先生() {
        let defaults = makeDefaults()
        defaults.set("消えたキャラ", forKey: SessionPreferences.characterKey)
        #expect(SessionPreferences(defaults: defaults, catalog: CharacterCatalog(characters: [.haru])).selectedCharacter == .haru)
    }
}

/// テストのバンドルには characters.json がない（`Bundle(for:)` で一覧を読めないときを作る）
private final class EmptyBundleMarker {}
