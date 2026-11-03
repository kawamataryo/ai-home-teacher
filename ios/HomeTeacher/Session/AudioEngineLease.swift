import Foundation

/// AVAudioEngine（マイク + voice processing）を動かしてよい持ち主を 1 つに決める（#75）。
///
/// 学習セッション画面と音声の検証画面（デバッグ）は、それぞれ自分のエンジンを持つ。
/// 2 つが同時に動くと voice processing がぶつかり、戻ったあとセッションのマイクが動かなくなる。
/// 借りるときは、いまの持ち主に `audioLeaseRevoked()` で（同期的に）止めてもらってから自分が動かす。
@MainActor
protocol AudioEngineLeaseHolder: AnyObject {
    /// ほかの持ち主が借りた。すぐ（同期的に）エンジンを止めること
    func audioLeaseRevoked()
}

@MainActor
final class AudioEngineLease {
    static let shared = AudioEngineLease()

    private weak var holder: (any AudioEngineLeaseHolder)?

    var currentHolder: (any AudioEngineLeaseHolder)? { holder }

    /// エンジンを動かす前に呼ぶ。ほかの持ち主がいれば止めてもらう
    func acquire(_ next: any AudioEngineLeaseHolder) {
        if let holder, holder !== next { holder.audioLeaseRevoked() }
        holder = next
    }

    /// エンジンを止めたら呼ぶ（自分が持ち主のときだけ外れる）
    func release(_ owner: any AudioEngineLeaseHolder) {
        if holder === owner { holder = nil }
    }

    func isHeld(by owner: any AudioEngineLeaseHolder) -> Bool { holder === owner }
}
