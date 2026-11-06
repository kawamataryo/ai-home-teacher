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
        // 設定がなくても画面は動かす（Claude への呼び出しは通信せずにすぐ失敗し、端末の声の決まり文句で話す。#66）
        client = config.map { WorkerClient(config: $0) } ?? .unconfigured
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
    /// 見守り（#30）。画面の「見守りカメラ オン」に使う。台本の発話のときは自己テストが渡したものだけ
    private(set) var watchOver: WatchOver?
    /// 初めての許可の流れ（#66）。理由を話している間だけある
    private(set) var onboarding: PermissionOnboarding?
    /// 拒否されている許可の案内（#66）。なければ nil
    private(set) var permissionNotice: PermissionNotice?

    @ObservationIgnored let services: AppServices
    @ObservationIgnored private var microphone: MicrophoneSpeechInput?
    /// いま話している声（キャラを替えるときに差し替える）
    @ObservationIgnored private var currentVoice: TeacherVoice?
    @ObservationIgnored private(set) var audioMonitor: AudioSessionMonitor?
    @ObservationIgnored private var lease: AudioEngineLease = .shared
    /// 作り直したあとに出す、使っている認識エンジン
    @ObservationIgnored private var audioLabel = ""

    @ObservationIgnored private let permissions: any PermissionAuthorizing

    init(services: AppServices, permissions: any PermissionAuthorizing = SystemPermissions()) {
        self.services = services
        self.permissions = permissions
    }

    /// 起動引数 `-skipPermissionOnboarding`：許可の説明を飛ばす（人がボタンを押せない自動の確認で、マイクの聞き取りまで進めるため）。
    /// まだ決まっていない許可（カメラなど）は使わない。
    static var skipsPermissionOnboarding: Bool {
        ProcessInfo.processInfo.arguments.contains("-skipPermissionOnboarding")
    }

    /// マイクと先生の声を用意して、まとめ役を作る。`scriptedInput` を渡すとマイクを使わない（自己テスト・表示確認）
    func prepare(
        scriptedInput: ScriptedSpeechInput? = nil, clock: any ConversationClock = SystemConversationClock(), watchOver: WatchOver? = nil
    ) async {
        guard coordinator == nil else { return }
        let input: any SpeechInput
        let player: any SpeechAudioPlayer
        if let scriptedInput {
            input = scriptedInput
            player = AudioClipPlayer()
            audioStatus = "マイクなし（台本の発話）"
        } else {
            // いきなりシステムのダイアログを出さず、先生が理由を話してから聞く（#66）
            // 起動引数 -skipPermissionOnboarding（自動の確認用）では飛ばし、まだ決まっていない許可は使わない
            if !Self.skipsPermissionOnboarding, !PermissionOnboarding.pending(permissions).isEmpty {
                let flow = PermissionOnboarding(authorizer: permissions, voice: makeVoice(player: AudioClipPlayer()))
                onboarding = flow
                await flow.run()
                onboarding = nil
            }
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

        let voice = makeVoice(player: player)
        // カメラだけ拒否なら、撮影と見守りは使わずに声の会話を続ける（#66）
        let cameraState = permissions.state(of: .camera)
        let cameraAllowed = Self.skipsPermissionOnboarding ? cameraState == .granted : cameraState != .denied
        if scriptedInput == nil {
            let states = Dictionary(uniqueKeysWithValues: AppPermission.allCases.map { ($0, permissions.state(of: $0)) })
            permissionNotice = PermissionNotice(states: states, speechInputFailed: !isMicrophoneAvailable)
        }
        // 見守りは前のカメラ（ActivityWatcher）。「見て」の撮影の前後で見守りのカメラを止めて戻す
        var camera: (any PhotoCapturing)? = scriptedInput == nil && cameraAllowed ? CameraCapture() : nil
        let watching = watchOver ?? (scriptedInput == nil && cameraAllowed ? makeWatchOver(clock: clock) : nil)
        if let watching, let base = camera { camera = WatchAwarePhotoCapture(base: base, watchOver: watching) }
        self.watchOver = watching
        let coordinator = StudySessionCoordinator(dependencies: .init(
            client: services.client,
            input: input,
            voice: voice,
            store: services.store,
            sync: services.sync,
            parentMessages: services.store,
            clock: clock,
            // 選んだ先生の名前と話し方で話す（#118）
            library: PromptLibrary(character: preferences.selectedCharacter),
            decisions: services.decisions,
            preferences: preferences,
            // 自己テスト・表示確認（台本の発話）のときはカメラを使わない
            camera: camera,
            countdown: SystemSoundCountdown(),
            watchOver: watching
        ))
        self.coordinator = coordinator
        audioMonitor?.session = coordinator
        // 話し始めた文と時刻を記録に残す（デモ動画で声を合わせる・遅延の確認）
        voice.onPlaybackStart = { [weak coordinator] text, provider in coordinator?.trace("話し始めた[\(provider)]: \(text)") }
        if let sink = SessionTraceFile.fromLaunchArguments() {
            coordinator.onTrace = { sink.append($0) }
        }
        coordinator.listen()
        coordinator.trace("音声: \(audioStatus)")
        // 拒否されているものがあれば、何が使えないかを先生が端末の声で伝える
        if let permissionNotice {
            coordinator.trace("許可の案内: \(permissionNotice.parentMessage)")
            await voice.say(permissionNotice.childLine)
        }
    }

    /// 先生の声。Worker の設定がなければ端末の声（AVSpeechSynthesizer）だけで話す
    private func makeVoice(player: any SpeechAudioPlayer) -> TeacherVoice {
        let (primary, cache) = voiceParts(for: preferences.selectedCharacter)
        let voice = TeacherVoice(
            primary: primary,
            fallback: services.config == nil ? nil : SystemTTSProvider(),
            player: player,
            lipSync: lipSync,
            phraseCache: cache
        )
        currentVoice = voice
        return voice
    }

    /// キャラの声と定型句。声と定型句は必ず同じキャラのものを組にする
    private func voiceParts(for character: TeacherCharacter) -> (primary: any TTSProvider, phraseCache: PhraseCache?) {
        let primary: any TTSProvider = services.config.map { $0.ttsProvider.makeProvider(client: services.client, voice: character.voice) } ?? SystemTTSProvider()
        return (primary, try? PhraseCache(preferredProvider: primary.identifier, character: character))
    }

    /// 選ぶ画面で話す声。セッションの声（マイクと同じエンジン）を借りる。まだなければ自分の声を作る
    func introVoice() -> TeacherVoice {
        currentVoice ?? makeVoice(player: AudioClipPlayer())
    }

    /// 選ぶ画面で、キャラの声に替える（選択は変えない。閉じたら `applySelectedCharacter` で戻す）
    func useVoice(of character: TeacherCharacter, on voice: TeacherVoice) {
        let (primary, cache) = voiceParts(for: character)
        voice.use(primary: primary, phraseCache: cache)
    }

    /// 初めて開いたときにキャラを選んでもらうか。選ばなければ今までと同じ先生のまま
    var needsCharacterChoice: Bool {
        preferences.characterID == nil && preferences.catalog.selectableCharacters.count > 1 && !Self.skipsPermissionOnboarding
    }

    /// 選んだキャラの声にする。次に話す文から、話す文も定型句も同じ声になる（#120）
    func applySelectedCharacter() {
        let character = preferences.selectedCharacter
        let (primary, cache) = voiceParts(for: character)
        currentVoice?.use(primary: primary, phraseCache: cache)
        coordinator?.use(library: PromptLibrary(character: character))
        let config = services.config
        Task { await PhraseCache.warmUp(config: config, character: character) }
    }

    private func makeWatchOver(clock: any ConversationClock) -> WatchOver {
        let preferences = preferences
        return WatchOver(
            watcher: ActivityWatcher(), clock: clock,
            configuration: { preferences.watchOverConfiguration },
            makeJudge: WatchOver.judgeFactory()
        )
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
