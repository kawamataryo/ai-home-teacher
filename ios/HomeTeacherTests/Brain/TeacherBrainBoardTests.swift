import Foundation
import Testing
@testable import HomeTeacher

/// 会話（Haiku）の途中で黒板に図を出す（#70）。
struct TeacherBrainBoardTests {
    static let segmentBoard = #"{"title":"もとにする量とくらべる量","component":{"type":"segment_diagram","bars":[{"name":"もとにする量","segments":[{"length":10,"label":"1200円"}],"total_label":""},{"name":"くらべる量","segments":[{"length":7.5,"label":"？円"}],"total_label":""}]}}"#

    private func makeBrain(_ transport: MockTransport) throws -> TeacherBrain {
        let client = WorkerClient(baseURL: URL(string: "https://example.workers.dev")!, familyToken: "t", transport: transport)
        return TeacherBrain(client: client, systemPrompt: "先生", tools: try PromptLibrary().conversationTools())
    }

    private func collect(_ stream: AsyncThrowingStream<TeacherOutput, Error>) async throws -> [TeacherOutput] {
        var out: [TeacherOutput] = []
        for try await o in stream { out.append(o) }
        return out
    }

    @Test func 話してから図を出すと文のあとに図が流れtool_resultと対になる() async throws {
        let transport = MockTransport(body: SSEFixture.toolStream(
            text: "もとにする量は、くらべるもとになる量だよ。黒板を見てね。", name: "show_board", inputJSON: Self.segmentBoard
        ))
        let brain = try makeBrain(transport)
        let outputs = try await collect(await brain.respondWithBoards(to: "ねえ先生、もとにする量ってなに？"))

        #expect(outputs.count == 3)
        #expect(outputs[0] == .sentence("もとにする量は、くらべるもとになる量だよ。"))
        #expect(outputs[1] == .sentence("黒板を見てね。"))
        guard case .board(.component(let title, .segmentDiagram(let diagram))) = outputs[2] else {
            Issue.record("線分図が流れていない: \(outputs)")
            return
        }
        #expect(title == "もとにする量とくらべる量")
        #expect(diagram.bars.map(\.name) == ["もとにする量", "くらべる量"])
        // 言葉で話したので、続きは呼ばない
        #expect(await transport.requests.count == 1)

        let messages = await brain.history.messages
        #expect(messages.map(\.role) == [.user, .assistant, .user])
        guard case .toolUse(let id, "show_board", _)? = messages[1].content.last else {
            Issue.record("tool_use が履歴にない")
            return
        }
        #expect(messages[2].content == [.toolResult(toolUseID: id, content: TeacherBrain.boardResultText)])
        // 次の子どもの発話は tool_result と同じ user メッセージにまとまる（API が受け付ける形）
        await brain.recordUserUtterance("なるほど")
        let next = await brain.makeRequest()
        #expect(next.messages.last?.content == [.toolResult(toolUseID: id, content: TeacherBrain.boardResultText), .text("なるほど")])
    }

    @Test func 文だけの返事では図を流さない() async throws {
        let transport = MockTransport(body: SSEFixture.toolStream(text: "黒板を見てね。", name: "show_board", inputJSON: Self.segmentBoard))
        let brain = try makeBrain(transport)
        var sentences: [String] = []
        for try await s in await brain.respond(to: "x") { sentences.append(s) }
        #expect(sentences == ["黒板を見てね。"])
    }

    @Test func 図だけ先に出したら図を流してから続きの言葉をもらう() async throws {
        let transport = MockTransport(responses: [
            .init(body: SSEFixture.toolStream(text: "", name: "show_board", inputJSON: Self.segmentBoard)),
            .init(body: SSEFixture.textStream(["黒板を見て。", "上がもとにする量だよ。"])),
        ])
        let brain = try makeBrain(transport)
        let outputs = try await collect(await brain.respondWithBoards(to: "もとにする量ってなに？"))
        #expect(outputs.count == 3)
        guard case .board = outputs.first else {
            Issue.record("図が最初に流れていない: \(outputs)")
            return
        }
        #expect(Array(outputs.dropFirst()) == [.sentence("黒板を見て。"), .sentence("上がもとにする量だよ。")])
        #expect(await transport.requests.count == 2)
    }

    @Test func 読めない図は出さずに出せなかったと伝える() async throws {
        let transport = MockTransport(body: SSEFixture.toolStream(
            text: "黒板に書くね。", name: "show_board", inputJSON: #"{"title":"x","component":{"type":"pie_chart"}}"#
        ))
        let brain = try makeBrain(transport)
        let outputs = try await collect(await brain.respondWithBoards(to: "x"))
        #expect(outputs == [.sentence("黒板に書くね。")])
        let messages = await brain.history.messages
        guard case .toolResult(_, let content)? = messages.last?.content.last else {
            Issue.record("tool_result がない")
            return
        }
        #expect(content == TeacherBrain.boardFailedText)
    }
}
