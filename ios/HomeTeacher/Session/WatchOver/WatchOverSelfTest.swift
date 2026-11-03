import Observation
import SwiftUI
import UIKit

/// 起動引数 `-autoWatch`：見守り（#30）の流れを、カメラを使わずに合成した見え方で通す自己テスト（シミュレーターでも動く）。
///
/// 動く → 止まる（6 秒で「手が止まった」とみなす）→ 先生の「どこか考え中？ちょっと見せて？」→ 子ども「うん、見て」（同意）
/// → 席を立つ（4 秒でタイマーが止まる）→ 戻る（タイマーが動く）→ 終わり、の順に流し、記録をログに出す。
/// 判定は自己テスト用に「声をかける」と答える（本番は JevNudgeJudge か規則）。カメラはないので撮影は省略される。
/// 結果はログの `WATCH_SELFTEST_BEGIN` 〜 `WATCH_SELFTEST_END` に出す。
@MainActor
@Observable
final class WatchOverSelfTest {
    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("-autoWatch") }

    /// 自己テスト用に短くした見守りの設定
    static let configuration = StallDetector.Configuration(stallAfter: .seconds(6), awayAfter: .seconds(4), returnAfter: .seconds(1))
    static let consentLine = "うん、見て"

    enum Scene: String {
        case moving = "手を動かしている"
        case still = "手が止まっている（顔はある）"
        case empty = "席を立った（誰もいない）"

        var sample: ActivitySample {
            switch self {
            case .moving: ActivitySample(facePresent: true, handsVisible: true, frameMotion: 0.1, handMotion: 0.08)
            case .still: ActivitySample(facePresent: true, handsVisible: false, frameMotion: 0.002, handMotion: nil)
            case .empty: ActivitySample(facePresent: false, handsVisible: false, frameMotion: 0.001, handMotion: nil)
            }
        }
    }

    private(set) var lines: [String] = []
    private(set) var isFinished = false
    let model: SessionAppModel
    private let input = ScriptedSpeechInput()
    private let watcher = SyntheticActivityWatcher()
    private var traces: [String] = []

    init(services: AppServices) {
        model = SessionAppModel(services: services)
    }

    func run() async {
        record("見守りの自己テスト開始（\(UIDevice.current.model) / iOS \(UIDevice.current.systemVersion)）")
        let watchOver = WatchOver(
            watcher: watcher, clock: SystemConversationClock(),
            configuration: { Self.configuration },
            makeJudge: { _ in SelfTestNudgeJudge() }
        )
        await model.prepare(scriptedInput: input, watchOver: watchOver)
        guard let coordinator = model.coordinator else {
            record("まとめ役を作れなかった")
            return finish([])
        }
        coordinator.onTrace = { [weak self] in
            self?.traces.append($0)
            self?.record("  · \($0)")
        }
        var results: [String] = []

        await coordinator.start()
        guard await waitUntil(seconds: 40, { coordinator.completedReplies >= 1 && coordinator.conversationState == .idle }) else {
            record("最初のひと言が終わらなかった")
            return finish(results)
        }
        results.append("- 見守りカメラ: \(watchOver.isWatching ? "オン（画面に目の印）" : "オフ")")

        play(.moving)
        try? await Task.sleep(for: .seconds(2))
        play(.still)
        let asked = await waitUntil(seconds: 30) {
            self.traced("見守りの声かけ") && coordinator.conversationState == .idle && watchOver.isAwaitingConsent
        }
        results.append(asked ? "- 手が止まった → 先生「\(WatchOver.checkInLines.joined())」" : "- 手が止まっても声をかけなかった")

        let before = coordinator.completedReplies
        record("子ども: 「\(Self.consentLine)」")
        input.say(Self.consentLine)
        let consented = await waitUntil(seconds: 20) { self.traced("見せてくれる") }
        results.append(consented ? "- 「\(Self.consentLine)」を同意として受け取った（撮影へ。カメラなしなので省略）" : "- 同意として受け取らなかった")
        _ = await waitUntil(seconds: 40) { coordinator.completedReplies > before && coordinator.conversationState == .idle }

        play(.empty)
        let paused = await waitUntil(seconds: 20) { coordinator.timer?.status == .paused }
        results.append(paused ? "- 席を立った → タイマーを止めた" : "- 席を立ってもタイマーが止まらなかった")
        play(.still)
        let resumed = await waitUntil(seconds: 20) { coordinator.timer?.status == .running }
        results.append(resumed ? "- 戻った → タイマーを動かした" : "- 戻ってもタイマーが動かなかった")
        watcher.stopPlaying()

        input.say("終わり")
        let ended = await waitUntil(seconds: 90) { coordinator.phase == .idle }
        results.append(ended ? "- 終わり: 見守りカメラ \(watchOver.isWatching ? "オンのまま" : "オフ")" : "- 終わり: 終わらなかった")
        finish(results)
    }

    private func play(_ scene: Scene) {
        record("見え方: \(scene.rawValue)")
        watcher.play(scene.sample)
    }

    private func traced(_ text: String) -> Bool {
        traces.contains { $0.contains(text) }
    }

    private func finish(_ results: [String]) {
        let report = (["### 見守りの自己テスト（-autoWatch）"] + results).joined(separator: "\n")
        print("WATCH_SELFTEST_BEGIN\n\(report)\nWATCH_SELFTEST_END")
        record(report)
        isFinished = true
    }

    private func waitUntil(seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return true
    }

    private func record(_ message: String) {
        lines.append(message)
        print("WATCH_SELFTEST \(message)")
    }
}

/// 合成した見え方を 250ms ごとに流す（カメラの代わり）
@MainActor
final class SyntheticActivityWatcher: ActivityWatching {
    var onSample: (@MainActor (ActivitySample) -> Void)?
    private var current: ActivitySample?
    private var loop: Task<Void, Never>?

    func start() async throws {
        loop = Task { [weak self] in
            while !Task.isCancelled {
                if let self, let sample = self.current { self.onSample?(sample) }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    func stop() async {
        loop?.cancel()
        loop = nil
    }

    func play(_ sample: ActivitySample) { current = sample }
    func stopPlaying() { current = nil }
}

/// 自己テスト用：いつも「声をかける」
@MainActor
final class SelfTestNudgeJudge: NudgeJudging {
    func shouldSpeakUp(_ context: NudgeContext) async -> Bool { true }
}

struct WatchOverSelfTestView: View {
    @State private var test: WatchOverSelfTest

    init(services: AppServices) {
        _test = State(initialValue: WatchOverSelfTest(services: services))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text(test.isFinished ? "見守りの自己テスト終了" : "見守りの自己テスト中…").font(.title2.bold())
                ForEach(Array(test.lines.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.callout.monospaced())
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await test.run() }
    }
}
