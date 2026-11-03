import Observation
import SwiftUI
import UIKit

/// 起動引数 `-autoSession`：実機でマイクを使わずに、学習セッションを通しで動かす自己テスト。
///
/// 台本の発話（`ScriptedSpeechInput`）を流し、先生が Worker（Claude）経由で返事できたかと、1 文目までの時間を記録する。
/// キーや Worker の設定がなければ返事は決まり文句になる（失敗として記録して、最後まで進める）。
/// 結果は Documents/session-selftest.txt と、ログの `SESSION_SELFTEST_BEGIN` 〜 `SESSION_SELFTEST_END` に出す。
@MainActor
@Observable
final class SessionSelfTest {
    static var isEnabled: Bool { ProcessInfo.processInfo.arguments.contains("-autoSession") }

    /// 子どもの発話の台本。呼びかけ語で始めるので、30 秒ルールの外でも先生が答える
    static let script = [
        "ねえ先生、割合の問題がよくわからないんだけど、どうやって考えればいい？",
        "ねえ先生、もとにする量ってなに？",
        "ねえ先生、ありがとう、やってみる",
    ]
    static let endCommand = "終わり"

    /// 答えを言う台本（#73）の問題。撮影のかわりに、この分析の結果を入れてから始める
    static let problem = AnalysisResult(
        analysis: ProblemAnalysis(
            kind: .thinking, problemSummary: "たて4cm、横6cmの長方形の面積を求める", answer: "24cm²",
            answerVariants: ["24平方センチメートル"], solution: "たて×横で4×6=24",
            hintSteps: ["何を求める問題かな？", "長さが書いてあるところはどこ？", "面積はどうやって求めたっけ？", "4×6を一緒に計算しよう。ということは？"]
        ),
        boards: []
    )
    /// 違う答えを 2 回（2 回目で次のヒントへ・励ます）→ 正しい答え（ほめる）
    static let answerScript = [
        "ねえ先生、答えは20平方センチ？",
        "ねえ先生、じゃあ10平方センチかな？",
        "ねえ先生、わかった！24平方センチだ！",
    ]

    private(set) var lines: [String] = []
    private(set) var isFinished = false
    let model: SessionAppModel
    private let input = ScriptedSpeechInput()
    private let started = Date()

    init(services: AppServices) {
        model = SessionAppModel(services: services)
    }

    func run() async {
        resetFile()
        record("自己テスト開始（\(UIDevice.current.model) / iOS \(UIDevice.current.systemVersion)）")
        record("接続先: \(model.services.config?.workerBaseURL.absoluteString ?? "未設定（Secrets.xcconfig）")")
        await model.prepare(scriptedInput: input)
        guard let coordinator = model.coordinator else {
            record("まとめ役を作れなかった")
            return finish()
        }
        coordinator.onTrace = { [weak self] in self?.record("  · \($0)") }

        await coordinator.start()
        var results: [String] = []
        guard await waitUntil(seconds: 40, { coordinator.completedReplies >= 1 && coordinator.conversationState == .idle }) else {
            record("最初のひと言が終わらなかった")
            return finish()
        }
        results.append(summary("最初のひと言", coordinator))

        for (index, line) in Self.script.enumerated() {
            let before = coordinator.completedReplies
            record("子ども: 「\(line)」")
            input.say(line)
            let replied = await waitUntil(seconds: 40) {
                coordinator.completedReplies > before && coordinator.conversationState == .idle
            }
            results.append(replied ? summary("\(index + 1)往復目", coordinator) : "- \(index + 1)往復目: 返事が終わらなかった")
        }

        // 答えを言う台本（#73）：違う → 違う（次のヒントへ・励ます）→ 正しい（ほめる・解けた）
        record("問題を入れる: \(Self.problem.analysis.problemSummary)（正答 \(Self.problem.analysis.answer)）")
        await coordinator.beginProblem(Self.problem)
        for (index, line) in Self.answerScript.enumerated() {
            let before = coordinator.completedReplies
            record("子ども: 「\(line)」")
            input.say(line)
            let replied = await waitUntil(seconds: 40) {
                coordinator.completedReplies > before && coordinator.conversationState == .idle
            }
            let label = "答え\(index + 1)"
            results.append(replied ? summary(label, coordinator) + answerSummary(coordinator) : "- \(label): 返事が終わらなかった")
        }
        let solved = coordinator.problems.last?.solvedBySelf == true
        results.append("- 解けた記録（solved_by_self）: \(solved ? "true" : "false")、ヒントの段階 \(coordinator.problems.last?.hintLevelReached ?? 0)")

        record("子ども: 「\(Self.endCommand)」")
        input.say(Self.endCommand)
        let ended = await waitUntil(seconds: 90) { coordinator.phase == .idle }
        results.append(ended ? "- 終わり: ふり返りを話して保存した" : "- 終わり: 終わらなかった")

        let report = (["### 学習セッションの自己テスト（-autoSession）"] + results).joined(separator: "\n")
        print("SESSION_SELFTEST_BEGIN\n\(report)\nSESSION_SELFTEST_END")
        record(report)
        finish()
    }

    private func summary(_ label: String, _ coordinator: StudySessionCoordinator) -> String {
        let source = coordinator.lastReplyFromWorker == true ? "Worker（Claude）から返事できた" : "Worker から返事できず決まり文句"
        let latency = coordinator.lastReplyLatency.map { "1文目まで \(Int($0 / .milliseconds(1)))ms" } ?? "-"
        let text = coordinator.lastReplyFromWorker == true ? "「\(coordinator.lastReplySentences.joined())」" : ""
        return "- \(label): \(source)、\(latency) \(text)"
    }

    /// 答えの判定・ヒントの段階・表情
    private func answerSummary(_ coordinator: StudySessionCoordinator) -> String {
        let judgement = coordinator.lastAnswerJudgement.map { "\($0.verdict.rawValue)（\($0.source.rawValue)）" } ?? "-"
        let ladder = coordinator.tutoring.map { "\($0.ladder.level)/\($0.ladder.stages.count)\($0.ladder.isSolved ? " 解けた" : "")" } ?? "-"
        return " ／ 判定 \(judgement)、段階 \(ladder)、表情 \(coordinator.lastReplyEmotion.rawValue)"
    }

    private func finish() {
        isFinished = true
        record("自己テスト終了（\(Int(Date().timeIntervalSince(started)))秒）")
    }

    /// 条件を満たすまで待つ。時間切れなら false
    private func waitUntil(seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return true
    }

    private static var fileURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appending(path: "session-selftest.txt")
    }

    private func resetFile() {
        guard let url = Self.fileURL else { return }
        try? Data().write(to: url)
    }

    private func record(_ message: String) {
        lines.append(message)
        print("SESSION_SELFTEST \(message)")
        guard let url = Self.fileURL, let handle = try? FileHandle(forWritingTo: url) else { return }
        handle.seekToEndOfFile()
        handle.write(Data("\(Date().formatted(.iso8601)) \(message)\n".utf8))
        try? handle.close()
    }
}

/// 自己テストの進み具合を出す画面
struct SessionSelfTestView: View {
    @State private var test: SessionSelfTest

    init(services: AppServices) {
        _test = State(initialValue: SessionSelfTest(services: services))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text(test.isFinished ? "自己テスト終了" : "自己テスト中…").font(.title2.bold())
                ForEach(Array(test.lines.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.callout.monospaced())
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await test.run() }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
    }
}
