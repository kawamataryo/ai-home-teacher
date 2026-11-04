import Observation
import SwiftUI
import UIKit

/// 起動引数 `-autoSession`：実機でマイクを使わずに、学習セッションを通しで動かす自己テスト。
/// 起動引数 `-autoSessionDemo`：同じ台本を、ふだんのセッション画面（先生・字幕・黒板・タイマー）で流す（デモ動画の撮影用）。
///
/// 台本の発話（`ScriptedSpeechInput`）を流し、先生が Worker（Claude）経由で返事できたかと、1 文目までの時間を記録する。
/// キーや Worker の設定がなければ返事は決まり文句になる（失敗として記録して、最後まで進める）。
/// 結果は Documents/session-selftest.txt と、ログの `SESSION_SELFTEST_BEGIN` 〜 `SESSION_SELFTEST_END` に出す。
@MainActor
@Observable
final class SessionSelfTest {
    /// 進み具合をどの画面で見せるか
    enum Mode: Equatable {
        /// 記録の文字を並べる画面（`-autoSession`）
        case log
        /// ふだんのセッション画面（`-autoSessionDemo`）。子どもが話す前に少し間をあける
        case screen
    }

    static func mode(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> Mode? {
        if arguments.contains("-autoSessionDemo") { return .screen }
        if arguments.contains("-autoSession") { return .log }
        return nil
    }

    static var isEnabled: Bool { mode() == .log }
    static var isDemoEnabled: Bool { mode() == .screen }

    /// 子どもの発話の台本。呼びかけ語で始めるので、30 秒ルールの外でも先生が答える
    static let script = [
        "ねえ先生、割合の問題がよくわからないんだけど、どうやって考えればいい？",
        "ねえ先生、もとにする量ってなに？",
        "ねえ先生、ありがとう、やってみる",
    ]
    /// 黒板の台本（起動引数 `-boardScript`。#105・#107）：理科と地理で自由に描く図を出し、図を使わない返事が 2 回続いたらしまう
    static let boardScript = [
        "ねえ先生、水ってあたためるとどう動くの？どうやって考えればいい？",
        "ねえ先生、方位ってどうやって見るの？",
        "ねえ先生、きのうサッカーしたんだ",
        "ねえ先生、ゴールも決めたよ",
    ]
    static var usesBoardScript: Bool { ProcessInfo.processInfo.arguments.contains("-boardScript") }
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
    let mode: Mode
    /// 子どもが話す前の間（画面で見せるときに、前の返事と字幕を読めるように）
    private var pauseBeforeUtterance: Duration { mode == .screen ? .seconds(2) : .zero }

    init(services: AppServices, mode: Mode = .log) {
        model = SessionAppModel(services: services)
        self.mode = mode
    }

    func run() async {
        resetFile()
        record("自己テスト開始（\(mode == .screen ? "セッション画面・" : "")\(UIDevice.current.model) / iOS \(UIDevice.current.systemVersion)）")
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

        for (index, line) in (Self.usesBoardScript ? Self.boardScript : Self.script).enumerated() {
            let before = coordinator.completedReplies
            await childSays(line)
            let replied = await waitUntil(seconds: 40) {
                coordinator.completedReplies > before && coordinator.conversationState == .idle
            }
            results.append(replied ? summary("\(index + 1)往復目", coordinator) : "- \(index + 1)往復目: 返事が終わらなかった")
        }

        // 答えを言う台本（#73）：違う → 違う（次のヒントへ・励ます）→ 正しい（ほめる・解けた）
        if !Self.usesBoardScript {
        record("問題を入れる: \(Self.problem.analysis.problemSummary)（正答 \(Self.problem.analysis.answer)）")
        await coordinator.beginProblem(Self.problem)
        for (index, line) in Self.answerScript.enumerated() {
            let before = coordinator.completedReplies
            await childSays(line)
            let replied = await waitUntil(seconds: 40) {
                coordinator.completedReplies > before && coordinator.conversationState == .idle
            }
            let label = "答え\(index + 1)"
            results.append(replied ? summary(label, coordinator) + answerSummary(coordinator) : "- \(label): 返事が終わらなかった")
        }
        let solved = coordinator.problems.last?.solvedBySelf == true
        results.append("- 解けた記録（solved_by_self）: \(solved ? "true" : "false")、ヒントの段階 \(coordinator.problems.last?.hintLevelReached ?? 0)")
        }

        await childSays(Self.endCommand)
        let ended = await waitUntil(seconds: 90) { coordinator.phase == .idle }
        results.append(ended ? "- 終わり: ふり返りを話して保存した" : "- 終わり: 終わらなかった")

        let report = (["### 学習セッションの自己テスト（-autoSession）"] + results).joined(separator: "\n")
        print("SESSION_SELFTEST_BEGIN\n\(report)\nSESSION_SELFTEST_END")
        record(report)
        finish()
    }

    private func childSays(_ line: String) async {
        if pauseBeforeUtterance > .zero { try? await Task.sleep(for: pauseBeforeUtterance) }
        record("子ども: 「\(line)」")
        input.say(line)
    }

    private func summary(_ label: String, _ coordinator: StudySessionCoordinator) -> String {
        let source = coordinator.lastReplyFromWorker == true ? "Worker（Claude）から返事できた" : "Worker から返事できず決まり文句"
        let latency = coordinator.lastReplyLatency.map { "1文目まで \(Int($0 / .milliseconds(1)))ms" } ?? "-"
        let text = coordinator.lastReplyFromWorker == true ? "「\(coordinator.lastReplySentences.joined())」" : ""
        // 会話の途中で出した黒板（#70）
        let board = coordinator.board.map { "、黒板: \(StudySessionCoordinator.describe($0))" } ?? "、黒板なし（先生だけ）"
        return "- \(label): \(source)、\(latency) \(text)\(board)"
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

    /// 記録の時刻。ISO 8601（ミリ秒まで）と UNIX 時刻（秒・ミリ秒まで）。録画と声の位置を合わせるのに使う
    static func timestamp(_ date: Date) -> String {
        let iso = date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        return "\(iso) [\(String(format: "%.3f", date.timeIntervalSince1970))]"
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
        handle.write(Data("\(Self.timestamp(Date())) \(message)\n".utf8))
        try? handle.close()
    }
}

/// 自己テストを、ふだんのセッション画面で流す（`-autoSessionDemo`）。台本の発話と決まった問題で、先生は本番の Worker（Claude）が返す
struct SessionSelfTestDemoView: View {
    @State private var test: SessionSelfTest

    init(services: AppServices) {
        _test = State(initialValue: SessionSelfTest(services: services, mode: .screen))
    }

    var body: some View {
        SessionScreen(model: test.model, selfTest: test)
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
