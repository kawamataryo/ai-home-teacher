import Foundation
import Observation

/// 先生の状態（spec §3③）
enum AvatarState: String, CaseIterable, Sendable {
    /// 待機: まばたき・小さな揺れ
    case idle
    /// 子どもが話している: うなずき
    case listening
    /// 考え中: 首をかしげる
    case thinking
    /// ノートを見る
    case looking
    /// ふつうに話す
    case talking
    /// 褒める: 喜ぶ
    case praise
    /// 励ます: 応援
    case encourage
    /// 休憩: 伸び
    case `break`
}

/// Claude の応答に付く感情タグ
enum AvatarEmotion: String, CaseIterable, Sendable {
    case neutral
    case praise
    case encourage

    /// タグの文字列から作る。知らないタグや nil は neutral
    init(tag: String?) {
        let normalized = tag?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        self = AvatarEmotion(rawValue: normalized) ?? .neutral
    }
}

/// 会話の進行から先生に伝えるできごと。ConversationController からはこれを送る
enum AvatarEvent: Equatable, Sendable {
    case userStartedSpeaking
    case userStoppedSpeaking
    case thinkingStarted
    case speakingStarted(emotion: AvatarEmotion)
    case speakingEnded
    case lookAtNotebook
    case lookAwayFromNotebook
    case breakStarted
    case breakEnded
}

/// できごとから先生の状態を決める（RealityKit に依存しない純粋なロジック）
struct AvatarStateMachine: Sendable {
    private(set) var state: AvatarState = .idle
    /// 休憩中か（休憩中に話し終えたら伸びの状態に戻る）
    private(set) var isOnBreak = false

    var isSpeaking: Bool {
        [.talking, .praise, .encourage].contains(state)
    }

    /// 何もしていないときに戻る状態
    private var restingState: AvatarState {
        isOnBreak ? .break : .idle
    }

    @discardableResult
    mutating func handle(_ event: AvatarEvent) -> AvatarState {
        switch event {
        case .userStartedSpeaking:
            // 先生が話している途中でも、子どもが話し始めたら聞く
            state = .listening
        case .userStoppedSpeaking:
            if state == .listening { state = restingState }
        case .thinkingStarted:
            state = .thinking
        case .speakingStarted(let emotion):
            switch emotion {
            case .neutral: state = .talking
            case .praise: state = .praise
            case .encourage: state = .encourage
            }
        case .speakingEnded:
            if isSpeaking { state = restingState }
        case .lookAtNotebook:
            // 話している最中は口と身ぶりを優先する
            if !isSpeaking { state = .looking }
        case .lookAwayFromNotebook:
            if state == .looking { state = restingState }
        case .breakStarted:
            isOnBreak = true
            if !isSpeaking { state = .break }
        case .breakEnded:
            isOnBreak = false
            if state == .break { state = .idle }
        }
        return state
    }
}

/// 画面から使う窓口。会話の側は `send(_:)` でできごとを送り、AvatarView は `state` を表示する
@MainActor
@Observable
final class AvatarController {
    private(set) var state: AvatarState = .idle
    private var machine = AvatarStateMachine()

    func send(_ event: AvatarEvent) {
        state = machine.handle(event)
    }
}
