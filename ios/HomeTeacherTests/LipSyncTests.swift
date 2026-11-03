import Foundation
import Testing
@testable import HomeTeacher

/// 1 文字 0.1 秒ずつの文字タイミングを作る
private func alignment(_ text: String, step: Double = 0.1) -> TTSAlignment {
    let characters = text.map(String.init)
    return TTSAlignment(
        characters: characters,
        characterStartTimesSeconds: characters.indices.map { Double($0) * step },
        characterEndTimesSeconds: characters.indices.map { Double($0 + 1) * step }
    )
}

/// 各文字の真ん中の時刻での口の形
private func shapes(_ text: String, step: Double = 0.1) -> [MouthShape] {
    let timeline = LipSyncConverter.timeline(from: alignment(text, step: step))
    return text.indices.enumerated().map { index, _ in timeline.shape(at: (Double(index) + 0.5) * step) }
}

struct LipSyncConverterTests {
    @Test func ひらがなを母音にする() {
        #expect(shapes("あいうえお") == [.a, .i, .u, .e, .o])
        #expect(shapes("かきくけこ") == [.a, .i, .u, .e, .o])
        #expect(shapes("がっこう") == [.a, .closed, .o, .u])
    }

    @Test func カタカナも同じように変換する() {
        #expect(shapes("ノート") == [.o, .o, .o])
        #expect(shapes("ヴァイオリン") == [.a, .a, .i, .o, .i, .n])
    }

    @Test func 小さいかなは前の音の母音を置き換える() {
        // きょ → お、しゃ → あ
        #expect(shapes("きょう") == [.o, .o, .u])
        #expect(shapes("しゃしん") == [.a, .a, .i, .n])
        // 先頭にあっても母音として扱う
        #expect(shapes("ぁ") == [.a])
    }

    @Test func 長音は前の母音をのばす() {
        #expect(shapes("すーぱー") == [.u, .u, .a, .a])
        // 前に母音がなければ閉じる
        #expect(shapes("ー") == [.closed])
    }

    @Test func んと促音と句読点() {
        #expect(shapes("ん") == [.n])
        #expect(shapes("あっ、うん。") == [.a, .closed, .closed, .u, .n, .closed])
        #expect(shapes("は い！") == [.a, .closed, .i, .closed])
    }

    @Test func ま行ば行ぱ行は唇を閉じてから開く() {
        let timeline = LipSyncConverter.timeline(from: alignment("ま"))
        #expect(timeline.shape(at: 0.01) == .closed)
        #expect(timeline.shape(at: 0.06) == .a)
    }

    @Test func 漢字は長さに合わせてあと閉じを交互にする() {
        // 0.3 秒の漢字 1 文字 → 2 回開け閉めする
        let timeline = LipSyncConverter.timeline(from: alignment("今", step: 0.3))
        let opened = stride(from: 0.0, to: 0.3, by: 0.01).map { timeline.shape(at: $0) }
        #expect(opened.first == .a)
        #expect(opened.contains(.closed))
        let openings = zip(opened, opened.dropFirst()).filter { $0 == .closed && $1 == .a }.count
        #expect(openings == 1)
    }

    @Test func かな漢字まじりの文() {
        // 「今日は算数」: 漢字はあ/閉じ、かなは母音
        let text = "今日は算数"
        let timeline = LipSyncConverter.timeline(from: alignment(text, step: 0.15))
        #expect(timeline.shape(at: 0.02) == .a)       // 今
        #expect(timeline.shape(at: 0.32) == .a)       // は
        #expect(timeline.shape(at: 0.47) == .a)       // 算
        #expect(timeline.shape(at: 10) == .closed)    // 終わったら閉じる
    }

    @Test func 終わりと始まりの前は閉じる() {
        var a = alignment("あ")
        a.characterStartTimesSeconds = [0.5]
        a.characterEndTimesSeconds = [0.7]
        let timeline = LipSyncConverter.timeline(from: a)
        #expect(timeline.shape(at: 0.2) == .closed)
        #expect(timeline.shape(at: 0.6) == .a)
        #expect(timeline.shape(at: 0.8) == .closed)
        #expect(timeline.duration == 0.7)
    }

    @Test func 文字の間があいたら閉じる() {
        let a = TTSAlignment(
            characters: ["あ", "あ"],
            characterStartTimesSeconds: [0, 0.5],
            characterEndTimesSeconds: [0.2, 0.7]
        )
        let timeline = LipSyncConverter.timeline(from: a)
        #expect(timeline.shape(at: 0.1) == .a)
        #expect(timeline.shape(at: 0.3) == .closed)
        #expect(timeline.shape(at: 0.6) == .a)
    }

    @Test func 同じ口が続くところはまとめる() {
        let timeline = LipSyncConverter.timeline(from: alignment("ああか"))
        #expect(timeline.keyframes.map(\.shape) == [.a, .closed])
    }

    @Test func 空の入力() {
        let timeline = LipSyncConverter.timeline(from: TTSAlignment(characters: [], characterStartTimesSeconds: [], characterEndTimesSeconds: []))
        #expect(timeline.keyframes.isEmpty)
        #expect(timeline.shape(at: 0) == .closed)
    }

    @Test func ElevenLabsのJSONを読める() throws {
        let json = """
        {"characters":["は","い"],"character_start_times_seconds":[0.0,0.12],"character_end_times_seconds":[0.12,0.3]}
        """
        let decoded = try JSONDecoder().decode(TTSAlignment.self, from: Data(json.utf8))
        #expect(decoded.characters == ["は", "い"])
        #expect(decoded.characterEndTimesSeconds == [0.12, 0.3])
    }
}

struct AmplitudeLipSyncTests {
    @Test func 音量で開け閉めする_しきい値の間では前の状態を保つ() {
        var lipSync = AmplitudeLipSync(openThreshold: 0.1, closeThreshold: 0.05)
        #expect(lipSync.update(rms: 0.01) == .closed)
        #expect(lipSync.update(rms: 0.07) == .closed)   // まだ開かない
        #expect(lipSync.update(rms: 0.2) == .a)
        #expect(lipSync.update(rms: 0.07) == .a)        // まだ閉じない
        #expect(lipSync.update(rms: 0.01) == .closed)
    }

    @Test func RMSを計算する() {
        #expect(AmplitudeLipSync.rms([]) == 0)
        #expect(abs(AmplitudeLipSync.rms([0.5, -0.5, 0.5, -0.5]) - 0.5) < 1e-6)
    }
}

@MainActor
struct LipSyncPlayerTests {
    @Test func 再生時刻に合わせて口の形が変わる() {
        let player = LipSyncPlayer()
        var now: TimeInterval? = 0.05
        player.play(LipSyncConverter.timeline(from: alignment("あい"))) { now }
        #expect(player.currentShape == .a)
        now = 0.15
        #expect(player.update() == .i)
        #expect(!player.isFinished)
        now = 0.5
        #expect(player.update() == .closed)
        #expect(player.isFinished)
        // 止まったら閉じる
        now = nil
        #expect(player.update() == .closed)
    }

    @Test func 音量に合わせて開け閉めする() {
        let player = LipSyncPlayer()
        var level: Float? = 0.3
        player.followAmplitude { level }
        #expect(player.currentShape == .a)
        level = 0
        #expect(player.update() == .closed)
        player.stop()
        #expect(player.isFinished)
    }

    @Test func モデルの口のテクスチャを差し替える() async throws {
        let model = try await TeacherModel.load()
        try await model.preloadFaceTextures()
        let player = LipSyncPlayer()
        player.model = model
        player.play(LipSyncConverter.timeline(from: alignment("お"))) { 0.05 }
        #expect(player.currentShape == .o)
    }
}
