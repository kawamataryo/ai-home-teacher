import Foundation

/// 見守り（#30）から頼まれること。まとめ役の本体はできるだけ触らず、ここに置く
extension StudySessionCoordinator: WatchOverHost {
    var watchOverIsFocusing: Bool {
        phase == .active && sessionMode == .study && timer?.phase == .focus
    }

    var watchOverIsQuiet: Bool {
        phase == .active && conversationState == .idle && !isCapturing
    }

    /// 声かけを履歴に残して話す（子どもの「うん」がこれへの返事だとわかるように）
    func watchOverCheckIn(_ sentences: [String]) async -> Bool {
        guard watchOverIsQuiet, let controller else { return false }
        trace("見守りの声かけ: 「\(sentences.joined())」")
        let outcome = await controller.speak(AsyncStream { continuation in
            for sentence in sentences { continuation.yield(sentence) }
            continuation.finish()
        })
        guard outcome != .rejected else { return false }
        await brain?.recordTeacherUtterance(sentences.joined())
        addressingJudge?.teacherLastSaid = sentences.last
        return true
    }

    func watchOverPauseTimer() -> Bool {
        guard let timer, timer.status == .running else { return false }
        timer.pause()
        return true
    }

    func watchOverResumeTimer() {
        timer?.resume()
    }

    func watchOverTrace(_ message: String) {
        trace(message)
    }
}
