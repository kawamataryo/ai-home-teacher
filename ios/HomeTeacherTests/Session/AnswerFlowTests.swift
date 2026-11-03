import Foundation
import Testing
@testable import HomeTeacher

/// 返事の気持ちのしるしと、子どもの答えの判定 → ヒントの段階 → ほめる・励ます、をまとめ役を通して確かめる（#73）。
@MainActor
struct AnswerFlowTests {
    private func startSession(_ h: SessionHarness) async {
        await h.enqueueReply(["[neutral]こんにちは！"])
        await h.coordinator.start()
        _ = await eventually { h.coordinator.completedReplies >= 1 && h.coordinator.conversationState == .idle }
    }

    /// 問題（たて4cm・横6cm の長方形の面積、正答 24cm²）に取り組み中にする
    private func startProblem(_ h: SessionHarness) async {
        await startSession(h)
        await h.coordinator.beginProblem(SessionSelfTest.problem)
        #expect(h.coordinator.tutoring?.ladder.level == 1)
    }

    /// 子どもが話して、先生が返事を話し終えるまで
    private func turn(_ h: SessionHarness, _ utterance: String, reply: [String]) async {
        let before = h.coordinator.completedReplies
        await h.enqueueReply(reply)
        await h.say(utterance)
        _ = await eventually { h.coordinator.completedReplies > before && h.coordinator.conversationState == .idle }
    }

    private func lastSystemPrompt(_ h: SessionHarness) async -> String {
        systemText(await h.conversationRequests().last) ?? ""
    }

    // MARK: - 気持ちのしるし

    @Test func しるしは読み上げずに表情にする() async throws {
        let h = try SessionHarness()
        await startSession(h)
        #expect(h.voice.spoken == ["こんにちは！"])
        #expect(h.coordinator.lastReplyEmotion == .neutral)

        h.voice.holdsPlayback = true
        await h.enqueueReply(["[praise]", "そう、よく気づいたね！", "どうしてそう思った？"])
        await h.say("ねえ先生、たてと横をかけるんだ")
        // 話している間はほめるポーズ
        #expect(await eventually { h.avatarState == .praise })
        #expect(h.voice.spoken.last == "そう、よく気づいたね！")
        h.voice.finishCurrent()
        _ = await eventually { h.voice.spoken.last == "どうしてそう思った？" }
        h.voice.finishCurrent()
        #expect(await eventually { h.coordinator.conversationState == .idle })
        #expect(h.coordinator.lastReplyEmotion == .praise)
        #expect(!h.voice.spoken.joined().contains("praise"))
        // 履歴にはしるしを残す（次の返事でもしるしを付けてもらう）
        #expect(await h.lastAssistantText() == "[praise]そう、よく気づいたね！どうしてそう思った？")
        // 話し終えたら表情は戻り、次の定型句には持ち越さない
        #expect(await eventually { h.avatarState == .idle })
    }

    @Test func しるしがなければふつうの顔で話す() async throws {
        let h = try SessionHarness()
        await startSession(h)
        h.voice.holdsPlayback = true
        await h.enqueueReply(["えっと、どこから？"])
        await h.say("ねえ先生、次の問題やるね")
        #expect(await eventually { h.avatarState == .talking })
        h.voice.finishCurrent()
        #expect(await eventually { h.coordinator.conversationState == .idle })
        #expect(h.coordinator.lastReplyEmotion == .neutral)
    }

    @Test func ふり返りにはしるしを渡さず読み上げない() async throws {
        let h = try SessionHarness()
        await startSession(h)
        await turn(h, "ねえ先生、たてと横をかけるんだ", reply: ["[praise]そう！"])
        await h.transport.enqueue(.data, "/v1/claude", body: SessionReflectorTests.response(closing: "[praise]今日もよくがんばったね！"))

        await h.say("終わり")
        #expect(await eventually(timeout: .seconds(5)) { h.coordinator.phase == .idle })
        let reflection = try #require(await h.transport.bodyData(.data, "/v1/claude").first)
        // 会話（messages）にはしるしを入れない（システムプロンプトの teacher.md にはしるしの説明がある）
        let object = try #require(try JSONSerialization.jsonObject(with: reflection) as? [String: Any])
        let messages = try JSONSerialization.data(withJSONObject: object["messages"] ?? [])
        let body = String(decoding: messages, as: UTF8.self)
        #expect(body.contains("そう！"))
        #expect(!body.contains("[praise]"))
        #expect(!body.contains("[neutral]"))
        #expect(h.voice.spoken.last == "今日もよくがんばったね！")
    }

    // MARK: - 答えの判定

    @Test func 違う答えを2回で次のヒントへ進めて励まし正しい答えでほめる() async throws {
        // Jev なし（規則だけ）で通す
        let h = try SessionHarness()
        await startProblem(h)

        // 1 回目の違う答え: 段階は進まない。表情は Haiku のしるしのまま
        await turn(h, "ねえ先生、答えは20平方センチ？", reply: ["[encourage]おしい！", "どう考えた？"])
        #expect(h.coordinator.lastAnswerJudgement == AnswerJudgement(verdict: .wrong, source: .fallback))
        #expect(h.coordinator.tutoring?.ladder.level == 1)
        #expect(h.coordinator.lastReplyEmotion == .encourage)
        #expect(await lastSystemPrompt(h).contains("違う答えが1回あった"))

        // 2 回目: 次の段階へ進め、しるしがなくても励ます表情にする
        h.voice.holdsPlayback = true
        await h.enqueueReply(["長さが書いてあるところはどこかな？"])
        await h.say("ねえ先生、じゃあ10平方センチかな？")
        #expect(await eventually { h.avatarState == .encourage })
        h.voice.finishCurrent()
        #expect(await eventually { h.coordinator.conversationState == .idle })
        h.voice.holdsPlayback = false
        #expect(h.coordinator.tutoring?.ladder.level == 2)
        #expect(h.coordinator.lastReplyEmotion == .encourage)
        let encouraging = await lastSystemPrompt(h)
        #expect(encouraging.contains("今のヒントの段階：2/4"))
        #expect(encouraging.contains("2回まちがえたので、段階を1つ進めた"))

        // 正しい答え: すぐに「すごいじゃん！」（Haiku を待たない）→ 返事。ほめる表情で、解けたと記録する
        h.voice.holdsPlayback = true
        await h.transport.enqueue(.lines, "/v1/claude", [.hang])
        await h.say("ねえ先生、わかった！24平方センチだ！")
        #expect(await eventually { h.voice.spoken.last == ReplyCue.praisePhrase })
        #expect(await eventually { h.avatarState == .praise })
        #expect(h.coordinator.problems.last?.solvedBySelf == true)
        #expect(h.coordinator.problems.last?.hintLevelReached == 2)
        let solved = await lastSystemPrompt(h)
        #expect(solved.contains("自分で答えにたどりついた"))
        // 励ましの指示は 1 回の返事だけ
        #expect(!solved.contains("2回まちがえたので"))
        // 「すごいじゃん！」は履歴に入れない（子どもの発話のあとに先生の返事が続く形を崩さない）
        #expect(await h.lastAssistantText()?.contains(ReplyCue.praisePhrase) != true)
    }

    @Test func 解けたあとの返事はほめる表情で答えを繰り返してよい() async throws {
        // Jev だけが正答とみなした（「にじゅうよん」は規則の照合に当たらない）
        let judge = ScriptedAnswerJudge([.correct])
        let h = try SessionHarness(answerJudge: judge)
        await startProblem(h)

        await turn(h, "ねえ先生、にじゅうよん！", reply: ["そう、24cm²だね！", "どうしてそう思った？"])
        #expect(judge.utterances == ["ねえ先生、にじゅうよん！"])
        #expect(h.voice.spoken.suffix(3) == [ReplyCue.praisePhrase, "そう、24cm²だね！", "どうしてそう思った？"])
        #expect(h.coordinator.lastReplyEmotion == .praise)
        #expect(h.coordinator.lastReplySentences.first == ReplyCue.praisePhrase)
        #expect(h.coordinator.tutoring?.ladder.isSolved == true)
        #expect(h.coordinator.traceLines.contains("先生の表情: praise"))
    }

    @Test func 答えだった発話では撮影の依頼を確かめない() async throws {
        let camera = MockCamera()
        let h = try SessionHarness(camera: camera, answerJudge: ScriptedAnswerJudge([.wrong]))
        await startProblem(h)
        // 「みて」を含むが、答えとして判定された
        await turn(h, "ねえ先生、これでどうかな、10になったよ、みて", reply: ["おしい！"])
        #expect(camera.captureCount == 0)
        #expect(h.voice.spoken.last == "おしい！")
    }

    @Test func 問題がないときは判定しない() async throws {
        let judge = ScriptedAnswerJudge([.correct])
        let h = try SessionHarness(answerJudge: judge)
        await startSession(h)
        await turn(h, "ねえ先生、24だよ", reply: ["なんの数？"])
        #expect(judge.utterances.isEmpty)
        #expect(!h.voice.spoken.contains(ReplyCue.praisePhrase))
    }
}
