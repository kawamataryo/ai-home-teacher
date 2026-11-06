import Testing
@testable import HomeTeacher

/// キャラの名前での呼びかけ（#126）
struct CharacterCallTests {
    @Test func どのキャラも先生と呼んでも名前で呼んでも応える() {
        for character in CharacterCatalog().characters {
            let words = character.callWords
            #expect(words.contains("ねえ先生"), "\(character.id)")
            #expect(words.contains("ねえ\(character.name)"), "\(character.id)")
            #expect(Set(ConversationSettings.defaultCallWords).isSubset(of: Set(words)))
        }
    }

    @Test func 仲間の呼びかけの例に先生を使わない() {
        let catalog = CharacterCatalog()
        #expect(catalog.character(id: "haru").callExample == "ねえ先生")
        #expect(catalog.character(id: "sora").callExample == "ねえソラ")
        #expect(catalog.character(id: "sora").callName == "ソラ")
    }

    @Test func 名前で呼びかけを判定する() {
        let words = CharacterCatalog().character(id: "sora").callWords
        #expect(CallWordAddressingJudge.startsWithCallWord("ねえソラ、これわかんない", callWords: words))
        #expect(CallWordAddressingJudge.startsWithCallWord("ソラ、見て", callWords: words))
        #expect(CallWordAddressingJudge.startsWithCallWord("ねえ先生、これ", callWords: words))
        #expect(!CallWordAddressingJudge.startsWithCallWord("今日は雨だね", callWords: words))
    }

    @Test func 既定の先生の案内は今までと同じ() {
        #expect(SessionContent.boardHint(phase: .active).contains("「ねえ先生」"))
    }
}
