import Foundation
import Observation

/// 声かけの届け先。セッション層で `ConversationNudgeSpeaker` をつなぐ。
@MainActor
protocol NudgeSink: AnyObject {
    func deliver(_ nudge: TeacherNudge)
}

/// 声かけを `ConversationController.speak` で話す。
///
/// 子どもの話をさえぎらないよう、会話が待機（`.idle`）のときだけ話す。
/// 聞き取り中・考え中・発話中に届いた声かけは、待機に戻るまで取っておく。
/// （`speak` は考え中でも話せてしまうので、ここで待機かどうかを見る）
///
/// 取っておくのは最新の 1 つだけ。待っている間に次の区切りが来たら、古い声かけは捨てる
/// （「休憩しよっか」のあとに「あと5分がんばろう」が出ないように）。
///
/// 言い回しを変えてよい声かけ（`allowsVariation`）は、`rephrase` で言い換えてから話す。
/// 言い換えられなければ（失敗・時間切れ）定型句をそのまま話す。
@MainActor
final class ConversationNudgeSpeaker: NudgeSink {
    private let controller: ConversationController
    /// 言い回しを変える（NudgeRephraser）。nil なら定型句のまま
    private let rephrase: (@MainActor (TeacherNudge) async -> String?)?
    /// 待機に戻るのを待っている声かけ
    private(set) var pending: TeacherNudge?
    private var isSpeaking = false
    private var isObserving = false

    init(controller: ConversationController, rephrase: (@MainActor (TeacherNudge) async -> String?)? = nil) {
        self.controller = controller
        self.rephrase = rephrase
    }

    func deliver(_ nudge: TeacherNudge) {
        pending = nudge
        flush()
    }

    /// 待機中なら取っておいた声かけを話す。待機でなければ、状態が変わるのを見張る
    private func flush() {
        guard pending != nil, !isSpeaking else { return }
        guard controller.state == .idle else {
            observeState()
            return
        }
        guard let nudge = pending else { return }
        pending = nil
        isSpeaking = true
        Task { [weak self] in
            guard let self else { return }
            var text = nudge.text
            if nudge.allowsVariation, let rephrase = self.rephrase, let varied = await rephrase(nudge) {
                text = varied
            }
            let outcome = await self.controller.speak(text)
            self.isSpeaking = false
            switch outcome {
            case .rejected:
                // 話し始める直前に子どもが話し始めた。新しい声かけが来ていなければ取っておく
                if self.pending == nil { self.pending = nudge }
            case .completed, .interrupted:
                // 割り込まれた声かけは言い直さない
                break
            }
            self.flush()
        }
    }

    /// `controller.events` は購読者が 1 つ（セッション層）なので使わず、Observation で状態の変化を見る
    private func observeState() {
        guard !isObserving else { return }
        isObserving = true
        withObservationTracking {
            _ = controller.state
        } onChange: { [weak self] in
            // onChange は値が変わる前に呼ばれ、MainActor とは限らないので、MainActor に移ってから見直す
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isObserving = false
                self.flush()
            }
        }
    }
}
