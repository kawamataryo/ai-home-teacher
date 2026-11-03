import Foundation
import Observation
import OSLog
import SwiftData

/// アプリ全体で 1 つだけ持つもの（記憶のストアと同期）。起動時に同期し、つながったら同期する（#28）。
@MainActor
final class AppServices {
    let config: AppConfig?
    let client: WorkerClient
    let store: MemorySyncStore
    /// Worker の設定がないときは同期しない
    let sync: SyncService?
    private let logger = Logger(subsystem: "com.kawamataryo.HomeTeacher", category: "AppServices")

    init(config: AppConfig?) {
        self.config = config
        // 設定がなくても画面は動かす（Claude への呼び出しは失敗し、決まり文句で話す）
        client = WorkerClient(config: config ?? AppConfig(workerBaseURL: URL(string: "http://localhost:8787")!, familyToken: ""))
        let base: SwiftDataMemoryStore
        if !Self.isTestHost, let container = try? SwiftDataMemoryStore.makeContainer() {
            base = SwiftDataMemoryStore(modelContainer: container)
        } else {
            // 端末に保存できないときはメモリ上だけで続ける
            base = try! SwiftDataMemoryStore.inMemory()
        }
        store = MemorySyncStore(base: base)
        sync = config == nil ? nil : SyncService(client: client, store: store)
    }

    /// ユニットテストのホストとして起動したか（そのときはマイクも端末の保存も使わない）
    nonisolated static var isTestHost: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    /// 起動時に 1 回。テストのホストとして起動したときは何もしない
    func syncAtLaunch() async {
        guard !Self.isTestHost, let sync else { return }
        await sync.startMonitoring(NWPathConnectivityMonitor())
        let report = await sync.syncNow(reason: .appLaunch)
        logger.info("起動時の同期: \(String(describing: report.outcome), privacy: .public)")
    }

    /// Jev（TypeSafe AI）の判定。Worker の設定がなければ使わない（規則ベースだけ）
    var decisions: TeacherDecisions? {
        config.map { _ in TeacherDecisions(client: DecisionClient(worker: client)) }
    }
}

/// 学習セッション画面のもと。マイク・先生の声・まとめ役（StudySessionCoordinator）を用意する。
///
/// マイク（AudioPipeline）は画面を開いている間ずっと動かし、先生の声は同じエンジンに `EngineClipPlayer` でつなぐ。
/// エンジンを作ってから再生ノードをつなぐ順番は、#9 / #13 の実機検証と同じ。
/// マイクが使えないとき（シミュレーターなど）は AVAudioPlayer で再生し、ボタンだけで動かす。
///
/// 中断（電話・Siri）・機器の切り替え・エンジンの構成変更は `AudioSessionMonitor` が受けて作り直す（#75）。
/// 音声の検証画面がエンジンを借りたら（`AudioEngineLease`）止め、開発用メニューを閉じたら `reclaimAudio()` で作り直す。
@MainActor
@Observable
final class SessionAppModel: AudioEngineLeaseHolder {
    private(set) var coordinator: StudySessionCoordinator?
    private(set) var audioStatus = "準備中…"
    private(set) var isMicrophoneAvailable = false
    let lipSync = LipSyncPlayer()
    let preferences = SessionPreferences()

    @ObservationIgnored let services: AppServices
    @ObservationIgnored private var microphone: MicrophoneSpeechInput?
    @ObservationIgnored private(set) var audioMonitor: AudioSessionMonitor?
    @ObservationIgnored private var lease: AudioEngineLease = .shared
    /// 作り直したあとに出す、使っている認識エンジン
    @ObservationIgnored private var audioLabel = ""

    init(services: AppServices) {
        self.services = services
    }

    /// マイクと先生の声を用意して、まとめ役を作る。`scriptedInput` を渡すとマイクを使わない（自己テスト・表示確認）
    func prepare(scriptedInput: ScriptedSpeechInput? = nil, clock: any ConversationClock = SystemConversationClock()) async {
        guard coordinator == nil else { return }
        let input: any SpeechInput
        let player: any SpeechAudioPlayer
        if let scriptedInput {
            input = scriptedInput
            player = AudioClipPlayer()
            audioStatus = "マイクなし（台本の発話）"
        } else {
            let mic = MicrophoneSpeechInput()
            microphone = mic
            input = mic
            do {
                // 検証画面のエンジンが動いていたら止めてもらう（エンジンは同時に 1 つだけ）
                lease.acquire(self)
                let kind = try await mic.start()
                let clipPlayer = EngineClipPlayer(engine: mic.engine)
                player = clipPlayer
                isMicrophoneAvailable = true
                audioLabel = "\(kind.rawValue)・エコーキャンセル ON"
                audioStatus = audioLabel
                startAudioMonitor(microphone: mic, player: clipPlayer, clock: clock)
            } catch {
                player = AudioClipPlayer()
                audioStatus = "マイクを使えません: \(error.localizedDescription)"
            }
        }

        let system = SystemTTSProvider()
        let primary: any TTSProvider = services.config == nil ? system : ElevenLabsTTSProvider(client: services.client)
        let voice = TeacherVoice(
            primary: primary,
            fallback: services.config == nil ? nil : system,
            player: player,
            lipSync: lipSync,
            phraseCache: try? PhraseCache()
        )
        let coordinator = StudySessionCoordinator(dependencies: .init(
            client: services.client,
            input: input,
            voice: voice,
            store: services.store,
            sync: services.sync,
            clock: clock,
            decisions: services.decisions,
            preferences: preferences,
            // 自己テスト・表示確認（台本の発話）のときはカメラを使わない
            camera: scriptedInput == nil ? CameraCapture() : nil,
            countdown: SystemSoundCountdown()
        ))
        self.coordinator = coordinator
        audioMonitor?.session = coordinator
        coordinator.listen()
    }

    // MARK: - 音声の中断・貸し出し（#75）

    private func startAudioMonitor(microphone: MicrophoneSpeechInput, player: EngineClipPlayer, clock: any ConversationClock) {
        let recovery = SessionAudioRecovery(microphone: microphone, player: player)
        recovery.onRebuilt = { [weak self] kind in
            self?.audioLabel = "\(kind.rawValue)・エコーキャンセル ON"
        }
        let monitor = AudioSessionMonitor(
            source: NotificationAudioSessionEvents(engine: microphone.engine), target: recovery, clock: clock
        )
        monitor.onStateChange = { [weak self] state in self?.audioStateChanged(state) }
        audioMonitor = monitor
        monitor.start()
    }

    private func audioStateChanged(_ state: AudioSessionMonitor.State) {
        switch state {
        case .running: audioStatus = audioLabel
        case .interrupted: audioStatus = "音声が中断されています"
        case .rebuilding: audioStatus = "マイクを準備し直しています…"
        case .yielded: audioStatus = "検証画面がマイクを使っています"
        case .failed: audioStatus = "マイクを再開できませんでした"
        }
    }

    /// 検証画面がエンジンを借りた。すぐ止める
    func audioLeaseRevoked() {
        if let audioMonitor {
            audioMonitor.yieldAudio()
        } else {
            microphone?.suspend()
        }
    }

    /// 開発用メニューから戻った。検証画面に貸していたら、エンジンを作り直して聞き取りを再開する
    func reclaimAudio() {
        guard let audioMonitor else { return }
        lease.acquire(self)
        audioMonitor.reclaimAudio()
    }
}
