import Foundation
import os
import Synchronization

/// Jev の答え一式。
struct DecisionResult: Sendable, Equatable {
    /// 質問の名前ごとの答え。答えが来なかった・読めなかった質問は入らない
    let answers: [String: DecisionAnswer]
    /// 実際に答えたモデル（エイリアスとは違うことがある）
    let model: String?
    /// リクエストから答えを読み終わるまでの時間
    let latency: Duration

    subscript(_ key: String) -> DecisionAnswer? { answers[key] }
}

enum DecisionError: Error, Equatable {
    case timeout
}

/// Worker の /v1/decide を通して Jev（TypeSafe AI）に質問するクライアント。
/// 失敗・タイムアウトのときは nil を返す。呼び出し側は規則ベースの判定に切り替える。
struct DecisionClient: Sendable {
    static let path = "/v1/decide"
    static let defaultModel = "jev-latest"
    static let defaultTimeout: Duration = .milliseconds(800)

    let worker: WorkerClient
    let model: String
    let timeout: Duration

    private static let logger = Logger(subsystem: "com.kawamataryo.HomeTeacher", category: "Decision")

    init(worker: WorkerClient, model: String = Self.defaultModel, timeout: Duration = Self.defaultTimeout) {
        self.worker = worker
        self.model = model
        self.timeout = timeout
    }

    /// 同じ state に対する質問をまとめて 1 回のリクエストで聞く。
    /// `timeout` を省くとクライアントの既定値を使う。
    func decide(
        state: DecisionState,
        questions: [String: DecisionQuestion],
        timeout: Duration? = nil
    ) async -> DecisionResult? {
        guard !questions.isEmpty else { return nil }
        let keys = questions.keys.sorted().joined(separator: ",")
        let limit = timeout ?? self.timeout
        let clock = ContinuousClock()
        let start = clock.now
        // 子どもの発話が入るので、ログに出すのは質問の名前と時間と結果だけ
        func log(_ outcome: String) {
            let ms = Self.milliseconds(clock.now - start)
            Self.logger.info("decide \(keys, privacy: .public) \(outcome, privacy: .public) \(ms, privacy: .public)ms")
        }

        let body: Data
        do {
            body = try WorkerClient.encoder.encode(Request(model: model, state: state, questions: questions))
        } catch {
            log("encode-error")
            return nil
        }

        let data: Data
        do {
            let worker = self.worker
            data = try await Self.withTimeout(limit) {
                try await worker.postJSON(path: Self.path, body: body)
            }
        } catch DecisionError.timeout {
            log("timeout")
            return nil
        } catch let WorkerError.http(status, _) {
            log("http-\(status)")
            return nil
        } catch {
            log("error")
            return nil
        }

        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            log("decode-error")
            return nil
        }
        var answers: [String: DecisionAnswer] = [:]
        for (key, question) in questions {
            if let raw = response.answers[key], let answer = raw.answer(for: question) {
                answers[key] = answer
            }
        }
        let latency = clock.now - start
        log(answers.count == questions.count ? "ok" : "partial-\(answers.count)/\(questions.count)")
        return DecisionResult(answers: answers, model: response.model, latency: latency)
    }

    // MARK: - JSON

    private struct Request: Encodable {
        let model: String
        let state: DecisionState
        let questions: [String: DecisionQuestion]
    }

    /// 必須の項目は `answers` と、答えごとの `type` と値だけにして、ほかは欠けていても読む
    private struct Response: Decodable {
        let model: String?
        let answers: [String: RawAnswer]

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            model = try? container.decodeIfPresent(String.self, forKey: .model)
            // 知らない型（box など）や壊れた答えは、その質問だけ読み飛ばす
            let lossy = try container.decode([String: Lossy<RawAnswer>].self, forKey: .answers)
            answers = lossy.compactMapValues(\.value)
        }

        private enum CodingKeys: String, CodingKey { case model, answers }
    }

    private struct Lossy<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: any Decoder) throws {
            value = try? T(from: decoder)
        }
    }

    private struct RawAnswer: Decodable {
        let type: String
        let noul: Double?
        let choice: String?
        let score: Double?
        let confidence: Double?
        let probabilities: [String: Double]?

        func answer(for question: DecisionQuestion) -> DecisionAnswer? {
            switch question {
            case .boolean:
                guard type == "noul", let noul else { return nil }
                return .boolean(probability: noul)
            case let .choice(_, options):
                // こちらの選択肢にない名前が返ってきたら使わない
                guard type == "choice", let choice, let index = options.firstIndex(where: { $0.name == choice }) else {
                    return nil
                }
                let probabilities = options.map { self.probabilities?[$0.name] ?? 0 }
                return .choice(index: index, probabilities: probabilities, confidence: confidence)
            case let .score(_, levels):
                guard type == "score", let score, !levels.isEmpty else { return nil }
                let level = min(max(Int(score.rounded()), 0), levels.count - 1)
                let probabilities = levels.indices.map { self.probabilities?[String($0)] ?? 0 }
                return .score(value: score, level: level, probabilities: probabilities, confidence: confidence)
            }
        }
    }

    // MARK: - タイムアウト

    /// `operation` が `limit` 以内に終わらなければ `DecisionError.timeout` を投げる。
    /// 待ちきれなかった処理はキャンセルし、終わるのを待たずに戻る（キャンセルに応じない処理でも詰まらない）
    static func withTimeout<T: Sendable>(
        _ limit: Duration,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let gate = ResumeOnce<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.set(continuation)
                let work = Task {
                    do { gate.resume(with: .success(try await operation())) } catch { gate.resume(with: .failure(error)) }
                }
                let timer = Task {
                    try? await Task.sleep(for: limit)
                    if gate.resume(with: .failure(DecisionError.timeout)) { work.cancel() }
                }
                gate.onResume { timer.cancel(); work.cancel() }
            }
        } onCancel: {
            gate.resume(with: .failure(CancellationError()))
        }
    }

    /// 継続を 1 回だけ再開する。先に終わった方（処理・タイマー・キャンセル）が勝つ
    private final class ResumeOnce<T: Sendable>: Sendable {
        private struct State {
            var continuation: CheckedContinuation<T, any Error>?
            var pending: Result<T, any Error>?
            var finished = false
            var cleanup: (@Sendable () -> Void)?
        }

        private let state = Mutex(State())

        func set(_ continuation: CheckedContinuation<T, any Error>) {
            let pending: Result<T, any Error>? = state.withLock {
                if let pending = $0.pending { $0.pending = nil; return pending }
                $0.continuation = continuation
                return nil
            }
            // set の前にキャンセルされていたらすぐ返す
            if let pending { continuation.resume(with: pending) }
        }

        func onResume(_ cleanup: @escaping @Sendable () -> Void) {
            let runNow = state.withLock {
                if $0.finished { return true }
                $0.cleanup = cleanup
                return false
            }
            if runNow { cleanup() }
        }

        /// 最初の 1 回だけ true を返す
        @discardableResult
        func resume(with result: Result<T, any Error>) -> Bool {
            let (won, continuation, cleanup) = state.withLock { s -> (Bool, CheckedContinuation<T, any Error>?, (@Sendable () -> Void)?) in
                guard !s.finished else { return (false, nil, nil) }
                s.finished = true
                let c = s.continuation
                s.continuation = nil
                if c == nil { s.pending = result }
                let cleanup = s.cleanup
                s.cleanup = nil
                return (true, c, cleanup)
            }
            continuation?.resume(with: result)
            cleanup?()
            return won
        }
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let (seconds, attoseconds) = duration.components
        return Int(seconds) * 1000 + Int(attoseconds / 1_000_000_000_000_000)
    }
}
