import Foundation
import Testing
@testable import HomeTeacher

struct ReferenceImageFinderParsingTests {
    @Test func 候補は検索の順に並べ写真のないページを飛ばす() {
        let json = #"{"query":{"pages":[{"index":2,"title":"ゲーム","pageid":2},{"index":3,"title":"狩り","pageimage":"b.jpg","thumbnail":{"source":"https://example.org/b.jpg"}},{"index":1,"title":"オオカミ","pageimage":"a.jpg","thumbnail":{"source":"https://example.org/a.jpg"}}]}}"#
        let candidates = ReferenceImageFinder.parseCandidates(Data(json.utf8))
        #expect(candidates.map(\.pageTitle) == ["オオカミ", "狩り"])
        #expect(candidates.first?.fileName == "a.jpg")
    }

    @Test func 作者とライセンスからタグを除いて書く() {
        let json = #"{"query":{"pages":[{"imageinfo":[{"extmetadata":{"Artist":{"value":"<a href=\"x\">Gifu &amp; sizu</a>"},"LicenseShortName":{"value":"CC BY-SA 4.0"}}}]}]}}"#
        #expect(ReferenceImageFinder.parseCredit(Data(json.utf8)) == "写真：Gifu & sizu / CC BY-SA 4.0（ウィキメディア・コモンズ）")
    }

    @Test func 確認はOKだけ通し読めなければ出さない() {
        func verdict(_ text: String) -> Bool {
            ReferenceImageFinder.parseVerdict(Data(#"{"content":[{"type":"text","text":"\#(text)"}]}"#.utf8))
        }
        #expect(verdict("OK"))
        #expect(verdict(" ok "))
        #expect(!verdict("NG"))
        #expect(!verdict("OKではなくNG"))
        #expect(!verdict("わかりません"))
        #expect(!ReferenceImageFinder.parseVerdict(Data("こわれた".utf8)))
    }

    @Test func 入力を読む() {
        let ok = JSONValue.object(["query": .string(" 富士山 "), "caption": .string("日本一高い山")])
        #expect(ReferenceImageTool.parse(ok)?.query == "富士山")
        #expect(ReferenceImageTool.parse(.object(["caption": .string("x")])) == nil)
    }

    @Test func 同梱のツールの定義を読める() throws {
        let tools = try PromptLibrary().conversationTools()
        #expect(tools.map(\.name).contains(ReferenceImageTool.name))
        let check = try PromptLibrary().load(.referenceImageCheck, variables: ["query": "富士山"])
        #expect(check.contains("富士山"))
        #expect(!check.contains("{{"))
    }
}

/// 決まった順に HTTP の応答を返す（ウィキペディアと写真のダウンロード）。
private actor FakeWeb: HTTPTransport {
    private(set) var urls: [URL] = []
    let imageType: String

    init(imageType: String = "image/jpeg") {
        self.imageType = imageType
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw URLError(.badURL) }
        urls.append(url)
        var body = Data()
        var type = "application/json"
        if url.path().hasSuffix(".jpg") {
            body = Data("IMG:\(url.lastPathComponent)".utf8)
            type = imageType
        } else if url.query()?.contains("generator=search") == true {
            body = Data(#"{"query":{"pages":[{"index":1,"title":"本","pageimage":"a.jpg","thumbnail":{"source":"https://example.org/a.jpg"}},{"index":2,"title":"オオカミ","pageimage":"b.jpg","thumbnail":{"source":"https://example.org/b.jpg"}}]}}"#.utf8)
        } else {
            body = Data(#"{"query":{"pages":[{"imageinfo":[{"extmetadata":{"LicenseShortName":{"value":"CC BY 4.0"}}}]}]}}"#.utf8)
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": type])!
        return (body, response)
    }

    func lines(for request: URLRequest) async throws -> (AsyncThrowingStream<String, Error>, HTTPURLResponse) {
        throw URLError(.unsupportedURL)
    }
}

struct ReferenceImageFinderFlowTests {
    private func verdict(_ text: String) -> MockTransport.Response {
        .init(body: #"{"content":[{"type":"text","text":"\#(text)"}]}"#)
    }

    private func client(_ transport: MockTransport) -> WorkerClient {
        WorkerClient(baseURL: URL(string: "https://example.workers.dev")!, familyToken: "t", transport: transport)
    }

    @Test func 確認で断られた候補は飛ばして次を出す() async throws {
        let judge = MockTransport(responses: [verdict("NG"), verdict("OK")])
        let web = FakeWeb()
        let finder = ReferenceImageFinder(client: client(judge), transport: web)
        let image = try #require(await finder.find(query: "オオカミ", caption: "オオカミの写真"))
        #expect(String(decoding: image.data, as: UTF8.self) == "IMG:b.jpg")
        #expect(image.caption == "オオカミの写真")
        #expect(image.credit.contains("CC BY 4.0"))
        // 確認には写真そのものを送る
        let bodies = await judge.requestBodies()
        #expect(bodies.count == 2)
        let json = try #require(try JSONSerialization.jsonObject(with: bodies[0]) as? [String: Any])
        let content = try #require((json["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])
        #expect(content[0]["type"] as? String == "image")
        #expect(json["model"] as? String == "claude-haiku-5-5")
    }

    @Test func すべて断られたら出さない() async {
        let judge = MockTransport(responses: [verdict("NG"), verdict("NG")])
        let finder = ReferenceImageFinder(client: client(judge), transport: FakeWeb())
        #expect(await finder.find(query: "オオカミ", caption: "") == nil)
    }

    @Test func 確認できないときは出さない() async {
        let judge = MockTransport(responses: [.init(status: 500, body: "{}"), .init(status: 500, body: "{}")])
        let finder = ReferenceImageFinder(client: client(judge), transport: FakeWeb())
        #expect(await finder.find(query: "オオカミ", caption: "") == nil)
    }

    @Test func 画像でない形式は確かめずに飛ばす() async {
        let judge = MockTransport(responses: [])
        let finder = ReferenceImageFinder(client: client(judge), transport: FakeWeb(imageType: "image/tiff"))
        #expect(await finder.find(query: "オオカミ", caption: "") == nil)
        #expect(await judge.requestBodies().isEmpty)
    }
}

private struct StubFinder: ReferenceImageFinding {
    var image: ReferenceImage?
    func find(query: String, caption: String) async -> ReferenceImage? { image }
}

struct TeacherBrainReferenceImageTests {
    private static let sample = ReferenceImage(query: "土星", caption: "土星のわ", credit: "写真：x", data: Data([1]))

    private func toolReply() -> String {
        SSEFixture.toolStream(text: "写真を探してみるね。", name: ReferenceImageTool.name, inputJSON: #"{"query":"土星","caption":"土星のわ"}"#)
    }

    private func run(finder: ReferenceImageFinding?, follow: String) async throws -> ([TeacherOutput], TeacherBrain, MockTransport) {
        let transport = MockTransport(responses: [.init(body: toolReply()), .init(body: SSEFixture.textStream([follow]))])
        let client = WorkerClient(baseURL: URL(string: "https://example.workers.dev")!, familyToken: "t", transport: transport)
        let brain = TeacherBrain(client: client, systemPrompt: "S", imageFinder: finder)
        var out: [TeacherOutput] = []
        for try await output in await brain.respondWithBoards(to: "土星見せて") { out.append(output) }
        return (out, brain, transport)
    }

    @Test func 見つけたら文_様子_写真の順に流して続きをもらう() async throws {
        let (outputs, brain, _) = try await run(finder: StubFinder(image: Self.sample), follow: "わが見えるかな？")
        #expect(outputs == [
            .sentence("写真を探してみるね。"),
            .research(.searchingImage(query: "土星")),
            .research(.foundImage(query: "土星")),
            .board(.referenceImage(Self.sample)),
            .sentence("わが見えるかな？"),
        ])
        let results = await brain.history.messages.flatMap(\.content).compactMap { block -> String? in
            if case .toolResult(_, let content) = block { content } else { nil }
        }
        #expect(results == [TeacherBrain.boardResultText])
    }

    @Test func 見つからなければそう伝えて言葉で続ける() async throws {
        let (outputs, brain, _) = try await run(finder: StubFinder(image: nil), follow: "土星はわがある星だよ。")
        #expect(outputs.contains(.research(.missedImage(query: "土星"))))
        #expect(outputs.last == .sentence("土星はわがある星だよ。"))
        #expect(!outputs.contains { if case .board = $0 { true } else { false } })
        let results = await brain.history.messages.flatMap(\.content).compactMap { block -> String? in
            if case .toolResult(_, let content) = block { content } else { nil }
        }
        #expect(results == [ReferenceImageTool.notFoundText])
    }

    @Test func 問題の答えを探す写真は探さずに断る() async throws {
        let transport = MockTransport(responses: [.init(body: toolReply()), .init(body: SSEFixture.textStream(["ヒントを出すね。"]))])
        let client = WorkerClient(baseURL: URL(string: "https://example.workers.dev")!, familyToken: "t", transport: transport)
        let brain = TeacherBrain(client: client, systemPrompt: "S", imageFinder: StubFinder(image: Self.sample))
        await brain.setImageGuard(AnswerLeakGuard(answer: "土星"))
        var outputs: [TeacherOutput] = []
        for try await output in await brain.respondWithBoards(to: "土星見せて") { outputs.append(output) }
        #expect(!outputs.contains { if case .board = $0 { true } else { false } })
        #expect(!outputs.contains { if case .research = $0 { true } else { false } })
        let results = await brain.history.messages.flatMap(\.content).compactMap { block -> String? in
            if case .toolResult(_, let content) = block { content } else { nil }
        }
        #expect(results == [ReferenceImageTool.answerBlockedText])
    }

    @Test func 写真を見せる前に割り込まれたら見せていないと履歴に残す() async throws {
        let (_, brain, _) = try await run(finder: StubFinder(image: Self.sample), follow: "どう？")
        await brain.markLastReplyBoardsNotShown()
        let results = await brain.history.messages.flatMap(\.content).compactMap { block -> String? in
            if case .toolResult(_, let content) = block { content } else { nil }
        }
        #expect(results == [TeacherBrain.boardNotShownText])
    }
}

struct ReferenceImageStatusTests {
    @Test func 写真を探す様子はウィキペディアを先に見せる() {
        var status = ResearchStatus(query: "")
        status.apply(.searchingImage(query: "土星"))
        #expect(status.headline == "写真をさがしているよ")
        #expect(status.sites.map(\.name) == ["ウィキペディア"])
        status.apply(.foundImage(query: "土星"))
        #expect(status.headline == "いい写真が見つかったよ！")
        status.collapse()
        #expect(status.headline == "ウィキペディアで見つけたよ")
    }

    @Test func 見つからなければ小さくしない() {
        var status = ResearchStatus(query: "")
        status.apply(.searchingImage(query: "土星"))
        status.apply(.missedImage(query: "土星"))
        status.collapse()
        #expect(status.phase == .failed)
        #expect(status.headline == "ぴったりの写真がなかったよ")
    }

    @Test func 答えの言葉は写真の説明からも隠す() {
        let guardian = AnswerLeakGuard(answer: "オリオン座")
        let image = ReferenceImage(query: "星座", caption: "オリオン座", credit: "c", data: Data([1]))
        let masked = guardian.mask(.referenceImage(image))
        #expect(masked.maskedCount == 1)
        if case .referenceImage(let shown) = masked.content { #expect(shown.caption == "？") } else { Issue.record("写真ではない") }
    }
}
