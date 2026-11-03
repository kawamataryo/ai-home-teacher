import SwiftUI
import UIKit

/// 学習セッション画面（アプリのメイン画面）。iPad を横置きで机に立てて使う想定。
///
/// - 左に大きな先生（AvatarView）、右に黒板（BoardView）
/// - 大きな開始・終了ボタン。声の「勉強スタート」「終わり」でも始めて終われる。キーボードは使わない
/// - 子どもが話したことを小さく字幕で出す
/// - 開発用の画面（音声の検証・タイマー・先生ギャラリー・黒板の部品）は右上の虫のボタンから
struct SessionScreen: View {
    @State var model: SessionAppModel
    /// 表示確認用に固定する状態（起動引数 `-sessionPreview`）。nil ならふつうに動かす
    var preview: SessionPreviewState?
    @State private var showsDebugMenu = false
    @State private var showsSettings = false

    var body: some View {
        NavigationStack {
            Group {
                if let coordinator = model.coordinator {
                    SessionContent(coordinator: coordinator, lipSync: model.lipSync, audioStatus: model.audioStatus)
                } else {
                    ProgressView("準備中…")
                        .font(.title2)
                }
            }
            .toolbar {
                // 見守りのカメラが動いている間は、子どもにわかるように出す（#30）
                ToolbarItem(placement: .topBarLeading) {
                    if let watchOver = model.watchOver, watchOver.isWatching {
                        WatchOverIndicator()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showsSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("設定")
                    .disabled(model.coordinator?.phase != .idle)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showsDebugMenu = true
                    } label: {
                        Image(systemName: "ladybug")
                    }
                    .accessibilityLabel("開発用メニュー")
                    // セッション中は開かない（検証画面はマイクを別に使う）
                    .disabled(model.coordinator?.phase != .idle)
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .sheet(isPresented: $showsSettings) {
            SessionSettingsView(preferences: model.preferences)
        }
        // 音声の検証画面はマイクを借りるので、閉じたらセッションのエンジンを作り直す（#75）
        .sheet(isPresented: $showsDebugMenu, onDismiss: { model.reclaimAudio() }) {
            DebugMenuView(config: model.services.config)
        }
        .task {
            if let preview {
                await model.prepare(scriptedInput: ScriptedSpeechInput())
                model.coordinator?.showPreview(preview)
            } else {
                await model.prepare()
            }
        }
        // 机に立てて 25 分使うので、自動ロックで止まらないようにする
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}

private struct SessionContent: View {
    let coordinator: StudySessionCoordinator
    let lipSync: LipSyncPlayer
    let audioStatus: String

    var body: some View {
        GeometryReader { geometry in
            let isWide = geometry.size.width > geometry.size.height
            let layout = isWide ? AnyLayout(HStackLayout(spacing: 24)) : AnyLayout(VStackLayout(spacing: 24))
            VStack(spacing: 20) {
                layout {
                    // 先生の大きさは固定し、黒板は残りに収める（中身が多くてもボタンを押し出さない）
                    teacherPanel
                        .frame(width: isWide ? geometry.size.width * 0.42 : nil)
                        .frame(height: isWide ? nil : geometry.size.height * 0.38)
                    boardPanel
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                }
                .frame(maxHeight: .infinity)
                controls
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
        }
        .background(Color(red: 0.97, green: 0.95, blue: 0.90).ignoresSafeArea())
    }

    // MARK: - 先生

    private var teacherPanel: some View {
        ZStack(alignment: .bottom) {
            AvatarView(state: coordinator.avatar.state, lipSync: lipSync)
                .background(
                    RoundedRectangle(cornerRadius: 28)
                        .fill(LinearGradient(
                            colors: [Color(red: 0.86, green: 0.93, blue: 1.0), Color(red: 0.98, green: 0.96, blue: 0.90)],
                            startPoint: .top, endPoint: .bottom
                        ))
                )
                .clipShape(RoundedRectangle(cornerRadius: 28))
                .overlay(alignment: .topLeading) {
                    if let timer = coordinator.timer {
                        FocusTimerView(timer: timer)
                            .scaleEffect(0.8)
                            .padding(12)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    StateBadge(phase: coordinator.phase, state: coordinator.conversationState, mode: coordinator.sessionMode)
                        .padding(16)
                }
            CaptionBubble(text: coordinator.caption)
                .padding(.bottom, 20)
                .padding(.horizontal, 20)
        }
    }

    // MARK: - 黒板

    /// 黒板は決まった大きさ（`boardDesignSize`）で描いて、場所に合わせて縮める（部品の中身が多くてもはみ出さない）
    private var boardPanel: some View {
        GeometryReader { geometry in
            let size = Self.boardDesignSize
            let scale = min(geometry.size.width / size.width, geometry.size.height / size.height)
            BoardView(content: coordinator.board ?? .text(Self.boardHint(phase: coordinator.phase)))
                .boardReveal(coordinator.boardReveal)
                // 図が替わるときは、消して書き直すように入れ替える
                .animation(.spring(duration: 0.45), value: coordinator.board)
                .frame(width: size.width, height: size.height)
                .scaleEffect(scale)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .overlay {
                    if let count = coordinator.captureCountdown {
                        Text("\(count)")
                            .font(.system(size: 160, weight: .heavy, design: .rounded))
                            .foregroundStyle(Chalk.yellow)
                            .shadow(radius: 8)
                            .transition(.scale)
                    } else if coordinator.isCapturing {
                        Label("ノートを見てるよ", systemImage: "camera.viewfinder")
                            .font(.title.bold())
                            .padding(20)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                }
        }
    }

    static let boardDesignSize = CGSize(width: 1100, height: 860)

    static func boardHint(phase: StudySessionCoordinator.Phase) -> String {
        switch phase {
        case .idle: "「勉強スタート」で始めよう！"
        case .starting: "準備中…"
        case .active: "わからないところは「ねえ先生」と話しかけてね。\n「これ見て」と言うと、ノートを見てヒントを書くよ。"
        case .ending: "今日のふり返り"
        }
    }

    // MARK: - ボタン

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 20) {
                SessionMainButton(phase: coordinator.phase) {
                    Task {
                        switch coordinator.phase {
                        case .idle: await coordinator.start()
                        case .active: await coordinator.end()
                        case .starting, .ending: break
                        }
                    }
                }
                if coordinator.phase == .active, coordinator.canCapture {
                    // 「これ見て」と言わなくても撮れる
                    Button {
                        Task { await coordinator.captureFromButton() }
                    } label: {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 34, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 84, height: 84)
                            .background(Circle().fill(coordinator.isCapturing ? Color.gray : Color.teal))
                    }
                    .buttonStyle(.plain)
                    .disabled(coordinator.isCapturing || coordinator.conversationState != .idle)
                    .accessibilityLabel("ノートを撮って見せる")
                }
            }
            Text(footnote)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var footnote: String {
        let hint = switch coordinator.phase {
        case .idle: "声で「勉強スタート」と言っても始められるよ"
        case .active: "「終わり」と言っても終われるよ"
        case .starting, .ending: ""
        }
        return [hint, audioStatus].filter { !$0.isEmpty }.joined(separator: "　・　")
    }
}

/// 大きな開始・終了ボタン
private struct SessionMainButton: View {
    let phase: StudySessionCoordinator.Phase
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                switch phase {
                case .idle:
                    Image(systemName: "play.fill")
                    Text("勉強スタート")
                case .active:
                    Image(systemName: "stop.fill")
                    Text("おわり")
                case .starting:
                    ProgressView().tint(.white)
                    Text("準備中…")
                case .ending:
                    ProgressView().tint(.white)
                    Text("ふり返り中…")
                }
            }
            .font(.system(size: 34, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(maxWidth: 520, minHeight: 84)
            .background(Capsule().fill(tint))
        }
        .buttonStyle(.plain)
        .disabled(phase == .starting || phase == .ending)
    }

    private var tint: Color {
        switch phase {
        case .idle: .orange
        case .active: Color(red: 0.35, green: 0.45, blue: 0.75)
        case .starting, .ending: .gray
        }
    }
}

/// 子どもの発話の字幕。控えめに出す
private struct CaptionBubble: View {
    let text: String

    var body: some View {
        if !text.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "ear")
                Text(text)
                    .lineLimit(2)
                    .truncationMode(.head)
            }
            .font(.title3)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .transition(.opacity)
        }
    }
}

/// いま先生が何をしているか（聞いてる・考え中・話してる）
private struct StateBadge: View {
    let phase: StudySessionCoordinator.Phase
    let state: ConversationState
    let mode: SessionMode

    var body: some View {
        if phase == .active {
            Label(text, systemImage: symbol)
                .font(.headline)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.thinMaterial, in: Capsule())
        }
    }

    private var text: String {
        switch state {
        case .idle: mode == .rest ? "休憩中" : "見守り中"
        case .listening: "聞いてるよ"
        case .thinking: "考え中…"
        case .speaking: "話してるよ"
        }
    }

    private var symbol: String {
        switch state {
        case .idle: mode == .rest ? "cup.and.saucer" : "eye"
        case .listening: "ear"
        case .thinking: "ellipsis.bubble"
        case .speaking: "waveform"
        }
    }
}

/// 見守りのカメラが動いている印。「見守り中」（会話が待機のときのバッジ）とは別に、カメラが動いているときだけ出す
private struct WatchOverIndicator: View {
    var body: some View {
        Label("先生が見守ってるよ", systemImage: "eye.circle.fill")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color(red: 0.25, green: 0.45, blue: 0.7))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.thinMaterial, in: Capsule())
            .accessibilityLabel("見守りカメラ オン。手の動きと顔があるかだけを見ています")
    }
}
