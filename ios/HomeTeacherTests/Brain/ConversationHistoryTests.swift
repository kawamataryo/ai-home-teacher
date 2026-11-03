import Testing
@testable import HomeTeacher

struct ConversationHistoryTests {
    @Test func 先生の発言はストリーミングでつながる() {
        var history = ConversationHistory()
        history.appendUser("先生")
        history.appendAssistantText("お、")
        history.appendAssistantText("どうした？")
        #expect(history.messages == [
            ChatMessage(role: .user, content: [.text("先生")]),
            ChatMessage(role: .assistant, content: [.text("お、どうした？")]),
        ])
    }

    @Test func 最後の先生の発言を文字数で切り詰める() {
        var history = ConversationHistory()
        history.appendUser("これ見て")
        history.appendAssistantText("どれどれ。表の2行目を見てみよう。")
        history.truncateLastAssistant(toCharacterCount: 5)
        #expect(history.lastAssistantText == "どれどれ。")
        #expect(history.messages.count == 2)
    }

    @Test func 文字数は書記素で数える() {
        var history = ConversationHistory()
        history.appendUser("a")
        history.appendAssistantText("👍🏽いいね")
        history.truncateLastAssistant(toCharacterCount: 2)
        #expect(history.lastAssistantText == "👍🏽い")
    }

    @Test func 文字数が長さ以上なら変えない() {
        var history = ConversationHistory()
        history.appendUser("a")
        history.appendAssistantText("いいね。")
        history.truncateLastAssistant(toCharacterCount: 100)
        #expect(history.lastAssistantText == "いいね。")
    }

    @Test func ゼロまで切り詰めたら発言を消して子どもの発話をまとめる() {
        var history = ConversationHistory()
        history.appendUser("先生")
        history.appendAssistantText("なになに？")
        history.truncateLastAssistant(toCharacterCount: 0)
        #expect(history.messages == [ChatMessage(role: .user, content: [.text("先生")])])

        history.appendUser("やっぱりいいや")
        #expect(history.messages == [ChatMessage(role: .user, content: [.text("先生"), .text("やっぱりいいや")])])
    }

    @Test func 間の先生の発言が消えたら前後の子どもの発話をまとめる() {
        var history = ConversationHistory()
        history.appendUser("1")
        history.appendAssistantText("A")
        history.appendUser("2")
        history.appendAssistantText("B")
        history.appendUser("3")
        // 最後の先生の発言は B
        history.truncateLastAssistant(toCharacterCount: 0)
        #expect(history.messages == [
            ChatMessage(role: .user, content: [.text("1")]),
            ChatMessage(role: .assistant, content: [.text("A")]),
            ChatMessage(role: .user, content: [.text("2"), .text("3")]),
        ])
    }

    @Test func ツールの呼び出しは切り詰めても残す() {
        var history = ConversationHistory()
        history.appendUser("a")
        history.appendAssistantText("うん。")
        history.append(.assistant, .toolUse(id: "t1", name: "x", input: .object([:])))
        history.truncateLastAssistant(toCharacterCount: 0)
        #expect(history.messages.last == ChatMessage(role: .assistant, content: [
            .toolUse(id: "t1", name: "x", input: .object([:])),
        ]))
    }

    @Test func 先生の発言がなければ何もしない() {
        var history = ConversationHistory()
        history.appendUser("a")
        history.truncateLastAssistant(toCharacterCount: 0)
        #expect(history.messages.count == 1)
    }
}
