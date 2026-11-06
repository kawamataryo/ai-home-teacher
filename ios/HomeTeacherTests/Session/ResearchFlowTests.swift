import Foundation
import Testing
@testable import HomeTeacher

struct ResearchStatusTests {
    private let sites = ["weathernews.jp", "tenki.jp"]

    @Test func 様子は調べている_見つかった_小さくするの順に変わる() {
        var status = ResearchStatus(query: "")
        status.apply(.searching(query: "天気"))
        #expect(status.phase == .searching)
        #expect(status.headline == "インターネットで調べているよ")
        #expect(status.isWorking)
        status.markSlow()
        #expect(status.headline == "もうちょっとで見つかりそう")
        status.apply(.found(query: "天気", sites: sites))
        #expect(status.phase == .found)
        #expect(!status.isWorking)
        #expect(status.sites.map(\.name) == ["ウェザーニュース", "tenki.jp"])
        status.collapse()
        #expect(status.isCompact)
        #expect(status.headline == "ウェザーニュース・tenki.jpで調べたよ")
    }

    @Test func 二回調べたらサイトを重ねずに足す() {
        var status = ResearchStatus(query: "")
        status.apply(.found(query: "a", sites: sites))
        status.apply(.searching(query: "b"))
        status.apply(.found(query: "b", sites: ["tenki.jp", "www.jma.go.jp"]))
        #expect(status.sites.map(\.host) == ["weathernews.jp", "tenki.jp", "www.jma.go.jp"])
    }

    @Test func 二回目が失敗しても先に見つかったもので答える() {
        var status = ResearchStatus(query: "")
        status.apply(.found(query: "a", sites: sites))
        status.apply(.failed(query: "b"))
        #expect(status.phase == .found)
    }

    @Test func 何も見つからなければ小さくせず正直に出す() {
        var status = ResearchStatus(query: "")
        status.apply(.failed(query: "a"))
        status.collapse()
        #expect(status.phase == .failed)
        #expect(status.headline == "うまく調べられなかったよ")
    }

    @Test func 知らないサイトはホスト名で出してfaviconの場所はホスト名だけ送る() throws {
        let site = ResearchSite(host: "www.example.com")
        #expect(site.name == "example.com")
        #expect(site.initial == "E")
        let url = try #require(site.faviconURL)
        #expect(url.host() == "www.google.com")
        #expect(url.query()?.contains("domain=www.example.com") == true)
    }

    @Test func 中身のない前置きを見分ける() {
        #expect(ResearchPreface.matches("調べたよ。"))
        #expect(ResearchPreface.matches("わかったよ！"))
        #expect(!ResearchPreface.matches("東京は晴れだって。"))
        #expect(ResearchPreface.matches("Note: I can't fully verify this."))
        #expect(ResearchPreface.matches("I found several results about the weather."))
        #expect(!ResearchPreface.matches("NASAの天文衛星スウィフトが地球に戻ってきたんだって。"))
    }

    @MainActor
    @Test func 同梱の定型句につなぎの声がある() throws {
        let phrases = try PhraseCache.loadManifest()
        let texts = phrases.map(\.text)
        #expect(texts.contains(StudySessionCoordinator.researchLead))
        #expect(texts.contains(StudySessionCoordinator.researchSlowLine))
        #expect(texts.contains(StudySessionCoordinator.imageLead))
        #expect(texts.contains(StudySessionCoordinator.researchFollowUp))
    }

    @Test func プレビューは各段階の様子を出す() {
        #expect(SessionPreviewState.researchSearching.researchStatus?.phase == .searching)
        #expect(SessionPreviewState.researchFound.researchStatus?.phase == .found)
        #expect(SessionPreviewState.researchAnswered.researchStatus?.isCompact == true)
        #expect(SessionPreviewState.board.researchStatus == nil)
    }
}

/// 検索のあいだ黙らないことを、セッションの流れで確かめる（#115）
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ResearchFlowTests {
    private func startSession(_ h: SessionHarness) async {
        await h.enqueueReply(["こんにちは！"])
        await h.coordinator.start()
        _ = await eventually { h.coordinator.completedReplies >= 1 && h.coordinator.conversationState == .idle }
    }

    private func reply(_ parts: String...) -> String {
        SearchSSE.start + parts.joined() + SearchSSE.stop
    }

    @Test func 先生が何も言わずに調べ始めたら声でつなぎカードを出す() async throws {
        let h = try SessionHarness()
        await startSession(h)
        let before = h.coordinator.completedReplies
        await h.transport.enqueue(.lines, "/v1/claude", body: reply(
            SearchSSE.search(0, query: "天気 今週"), SearchSSE.results(1), SearchSSE.text(2, "東京は晴れだって。")
        ))
        await h.say("ねえ先生、今週の天気は？")
        #expect(await eventually { h.coordinator.completedReplies > before && h.coordinator.conversationState == .idle })
        #expect(h.voice.spoken.suffix(2) == [StudySessionCoordinator.researchLead, "東京は晴れだって。"])
        #expect(h.coordinator.research?.sites.map(\.host) == ["tenki.jp", "ja.wikipedia.org"])
        // 話し終えたら小さくして、少しあとでしまう
        #expect(h.coordinator.research?.isCompact == true)
        h.clock.advance(by: StudySessionCoordinator.researchDismissDelay)
        #expect(await eventually { h.coordinator.research == nil })
    }

    @Test func 調べたあとの言いなおしと前置きは話さず履歴の位置はずれない() async throws {
        let h = try SessionHarness()
        await startSession(h)
        let before = h.coordinator.completedReplies
        await h.transport.enqueue(.lines, "/v1/claude", body: reply(
            SearchSSE.text(0, "ちょっと調べてみるね。"), SearchSSE.search(1, query: "天気"), SearchSSE.results(2),
            SearchSSE.text(3, "ちょっと調べてみるね。調べたよ。**東京**は晴れだって。")
        ))
        await h.say("ねえ先生、今週の天気は？")
        #expect(await eventually { h.coordinator.completedReplies > before && h.coordinator.conversationState == .idle })
        #expect(h.voice.spoken.suffix(2) == ["ちょっと調べてみるね。", "東京は晴れだって。"])
    }

    @Test func 調べたあとの答えは3文で止めて続きを聞き履歴もそろえる() async throws {
        let h = try SessionHarness()
        await startSession(h)
        let before = h.coordinator.completedReplies
        await h.transport.enqueue(.lines, "/v1/claude", body: reply(
            SearchSSE.text(0, "ちょっと調べてみるね。"), SearchSSE.search(1, query: "天気"), SearchSSE.results(2),
            SearchSSE.text(3, "一つ目だよ。二つ目だよ。三つ目だよ。四つ目だよ。五つ目だよ。")
        ))
        await h.say("ねえ先生、今週の天気は？")
        #expect(await eventually { h.coordinator.completedReplies > before && h.coordinator.conversationState == .idle })
        #expect(h.voice.spoken.suffix(5) == [
            "ちょっと調べてみるね。", "一つ目だよ。", "二つ目だよ。", "三つ目だよ。", StudySessionCoordinator.researchFollowUp,
        ])
        let said = await h.coordinator.brain?.history.lastAssistantText ?? ""
        #expect(!said.contains("四つ目"))
        #expect(said.hasSuffix(StudySessionCoordinator.researchFollowUp))
    }

    @Test func 調べものが遅いと一回だけ声をかけて考える定型句とは重ねない() async throws {
        let h = try SessionHarness()
        await startSession(h)
        await h.transport.enqueue(.lines, "/v1/claude", [.partial(SearchSSE.start + SearchSSE.search(0, query: "天気"))])
        await h.say("ねえ先生、今週の天気は？")
        #expect(await eventually { h.coordinator.research?.phase == .searching })
        h.clock.advance(by: .seconds(5))
        #expect(await eventually { h.voice.spoken.contains(StudySessionCoordinator.researchSlowLine) })
        #expect(h.coordinator.research?.phase == .slow)
        #expect(!h.voice.spoken.contains(StudySessionCoordinator.replyFiller))
        #expect(h.voice.spoken.filter { $0 == StudySessionCoordinator.researchSlowLine }.count == 1)
    }

    @Test func 割り込まれたらカードを消す() async throws {
        let h = try SessionHarness()
        await startSession(h)
        await h.transport.enqueue(.lines, "/v1/claude", [.partial(SearchSSE.start + SearchSSE.search(0, query: "天気"))])
        await h.say("ねえ先生、今週の天気は？")
        #expect(await eventually { h.coordinator.research != nil })
        h.input.send(.voiceStarted)
        #expect(await eventually { h.coordinator.research == nil })
    }
}
