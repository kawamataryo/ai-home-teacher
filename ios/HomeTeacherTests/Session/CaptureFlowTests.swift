import Foundation
import Testing
import UIKit
@testable import HomeTeacher

/// 「これ見て」→ 撮影 → 分析 → 先生のメモ → 黒板 → 読み上げ前の答え漏れ検査、をまとめ役を通して確かめる（#15）。
@MainActor
struct CaptureFlowTests {
    private static let stepCardsBoard = #"{"title":"面積の求め方","component":{"type":"step_cards","steps":[{"heading":"何を聞かれている？","detail":"長方形の面積"}]}}"#

    /// 分析（Sonnet）の応答。黒板の図も 1 枚付ける
    private static var analysisResponse: String {
        ProblemAnalyzerTests.response(blocks: [
            ProblemAnalyzerTests.toolUse("report_analysis", ProblemAnalyzerTests.thinkingInput),
            ProblemAnalyzerTests.toolUse("show_board", stepCardsBoard, id: "toolu_2"),
        ])
    }

    private func startSession(_ h: SessionHarness) async {
        await h.enqueueReply(["こんにちは！"])
        await h.coordinator.start()
        _ = await eventually { h.coordinator.completedReplies >= 1 && h.coordinator.conversationState == .idle }
    }

    @Test func これ見てと言うと撮影して分析し先生のメモと黒板を出す() async throws {
        let camera = MockCamera()
        let h = try SessionHarness(camera: camera)
        await startSession(h)
        // 1 回目の返事（撮影の依頼とわかって捨てる）→ 分析 → 写真を見たあとの返事
        await h.enqueueReply(["お、どれどれ。"])
        await h.transport.enqueue(.data, "/v1/claude", body: Self.analysisResponse)
        await h.enqueueReply(["長方形の問題だね。", "何を求めるのかな？"])

        await h.say("ねえ先生、これ見て")
        #expect(await eventually { h.voice.spoken.last == "何を求めるのかな？" })

        #expect(camera.captureCount == 1)
        #expect(h.voice.spoken.contains(StudySessionCoordinator.captureLead))
        #expect(!h.voice.spoken.contains("お、どれどれ。"))
        #expect(h.coordinator.board?.isComponent == true)
        #expect(h.coordinator.problems.map(\.summary) == ["たて4cm、横6cmの長方形の面積を求める"])

        // 送った写真は長辺 2048px の JPEG
        let analysis = try #require(await h.bodies(.data, "/v1/claude").first)
        let content = try #require((analysis["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]])
        let base64 = try #require((content.first?["source"] as? [String: Any])?["data"] as? String)
        let jpeg = try #require(Data(base64Encoded: base64))
        let image = try #require(UIImage(data: jpeg))
        #expect(max(image.size.width * image.scale, image.size.height * image.scale) == 2048)

        // 写真のあとの返事には先生のメモ（正答つき）が入り、撮影を頼んだ発話は履歴に残っている
        let request = try #require(await h.conversationRequests().last)
        let system = try #require(systemText(request))
        #expect(system.contains("先生のメモ"))
        #expect(system.contains("正答（子どもに言わない）：24cm²"))
        let texts = (request["messages"] as? [[String: Any]] ?? []).flatMap { ($0["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String } }
        #expect(texts.contains("ねえ先生、これ見て"))
        #expect(texts.contains(StudySessionCoordinator.photoShownTrigger))
        #expect(!texts.contains("お、どれどれ。"))
    }

    @Test func 撮影の依頼でなければ撮らない() async throws {
        let camera = MockCamera()
        let h = try SessionHarness(camera: camera)
        await startSession(h)
        await h.enqueueReply(["いいね、やってみよう。"])

        await h.say("ねえ先生、次の問題やるね")
        #expect(await eventually { h.voice.spoken.last == "いいね、やってみよう。" })
        #expect(camera.captureCount == 0)
    }

    @Test func 撮影ボタンでも撮れる() async throws {
        let camera = MockCamera()
        let defaults = try #require(UserDefaults(suiteName: "CaptureFlowTests-\(UUID().uuidString)"))
        let preferences = SessionPreferences(defaults: defaults)
        preferences.cameraPosition = .back
        let h = try SessionHarness(preferences: preferences, camera: camera)
        await startSession(h)
        await h.transport.enqueue(.data, "/v1/claude", body: Self.analysisResponse)
        await h.enqueueReply(["見せてくれてありがとう。"])

        await h.coordinator.captureFromButton()
        #expect(await eventually { h.voice.spoken.last == "見せてくれてありがとう。" })
        #expect(camera.captureCount == 1)
        #expect(camera.preparedPositions == [.back])
    }

    @Test func 撮れなかったらそう言って続ける() async throws {
        let camera = MockCamera()
        camera.fails = true
        let h = try SessionHarness(camera: camera)
        await startSession(h)

        await h.coordinator.captureFromButton()
        #expect(h.voice.spoken.last == StudySessionCoordinator.captureFailedLine)
        #expect(h.coordinator.isCapturing == false)
        #expect(await eventually { h.avatarState == .idle })
    }

    @Test func 答えを言いそうな文は差し替えて残りは話さない() async throws {
        let camera = MockCamera()
        let h = try SessionHarness(camera: camera)
        await startSession(h)
        await h.transport.enqueue(.data, "/v1/claude", body: Self.analysisResponse)
        await h.enqueueReply(["見せてくれてありがとう。"])
        await h.coordinator.captureFromButton()
        _ = await eventually { h.voice.spoken.last == "見せてくれてありがとう。" && h.coordinator.conversationState == .idle }

        await h.enqueueReply(["4×6を計算しよう。", "答えは24cm²だよ。", "だから面積は24cm²。"])
        await h.say("ねえ先生、答え教えて")
        #expect(await eventually { h.voice.spoken.last == AnswerLeakGuard.defaultReplacement && h.coordinator.conversationState == .idle })
        #expect(!h.voice.spoken.joined().contains("24"))
        // 履歴も差し替えた文にそろえる（次の返事で答えを繰り返さないように）
        let history = try #require(await h.lastAssistantText())
        #expect(!history.contains("24"))
        #expect(history.hasSuffix(AnswerLeakGuard.defaultReplacement))
    }

    @Test func 助けを求めるとヒントの段階を進めて先生のメモを組み直す() async throws {
        let camera = MockCamera()
        let h = try SessionHarness(camera: camera)
        await startSession(h)
        await h.transport.enqueue(.data, "/v1/claude", body: Self.analysisResponse)
        await h.enqueueReply(["見せてくれてありがとう。"])
        await h.coordinator.captureFromButton()
        _ = await eventually { h.voice.spoken.last == "見せてくれてありがとう。" && h.coordinator.conversationState == .idle }
        #expect(h.coordinator.tutoring?.ladder.level == 1)

        await h.enqueueReply(["どこに長さが書いてある？"])
        await h.say("ねえ先生、わかんない")
        #expect(await eventually { h.voice.spoken.last == "どこに長さが書いてある？" })
        #expect(h.coordinator.tutoring?.ladder.level == 2)
        let system = try #require(systemText(await h.conversationRequests().last))
        #expect(system.contains("今のヒントの段階：2/4"))

        // 自分で答えを言えたら、解けたとしてふり返りに渡す
        await h.enqueueReply(["そう！どうしてそう思った？"])
        await h.say("ねえ先生、24平方センチ？")
        #expect(await eventually { h.voice.spoken.last == "どうしてそう思った？" })
        #expect(h.coordinator.problems.last?.solvedBySelf == true)
        #expect(h.coordinator.problems.last?.hintLevelReached == 2)
    }
}

private extension BoardContent {
    var isComponent: Bool {
        if case .component = self { return true }
        return false
    }
}
