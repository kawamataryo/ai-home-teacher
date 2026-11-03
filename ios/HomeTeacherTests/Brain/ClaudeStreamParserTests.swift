import Testing
@testable import HomeTeacher

struct ClaudeStreamParserTests {
    private let parser = ClaudeStreamParser()

    private func parseAll(_ text: String) -> [ClaudeStreamEvent] {
        text.split(separator: "\n").compactMap { parser.parse(line: String($0)) }
    }

    @Test func テキストのストリームをイベントにする() {
        let events = parseAll(SSEFixture.textStream(["こんに", "ちは。"]))
        #expect(events == [
            .messageStart,
            .ping,
            .textDelta(index: 0, text: "こんに"),
            .textDelta(index: 0, text: "ちは。"),
            .contentBlockStop(index: 0),
            .messageDelta(stopReason: "end_turn"),
            .messageStop,
        ])
    }

    @Test func ツールの呼び出しをイベントにする() {
        let fixture = """
        data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"flag_for_parent","input":{}}}
        data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"reason\\":"}}
        data: {"type":"content_block_stop","index":1}
        data: {"type":"message_delta","delta":{"stop_reason":"tool_use"}}
        """
        #expect(parseAll(fixture) == [
            .toolUseStart(index: 1, id: "toolu_1", name: "flag_for_parent"),
            .inputJSONDelta(index: 1, partialJSON: #"{"reason":"#),
            .contentBlockStop(index: 1),
            .messageDelta(stopReason: "tool_use"),
        ])
    }

    @Test func エラーイベントを読む() {
        let line = #"data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#
        #expect(parser.parse(line: line) == .error(type: "overloaded_error", message: "Overloaded"))
    }

    @Test(arguments: [
        "event: content_block_delta",
        ": comment",
        "",
        "data: not json",
        #"data: {"type":"unknown_future_event"}"#,
        #"data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"…"}}"#,
    ])
    func 関係ない行は無視する(line: String) {
        #expect(parser.parse(line: line) == nil)
    }

    @Test func dataの後の空白はなくてもよい() {
        #expect(parser.parse(line: #"data:{"type":"message_stop"}"#) == .messageStop)
    }
}
