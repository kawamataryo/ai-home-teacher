import SwiftUI
import UIKit

/// 学習セッション画面（アプリのメイン画面）。iPad を横置きで机に立てて使う想定。
///
/// - 黒板に書いていないときは先生だけを大きく（黒板は横の小さな看板に使い方を書く）。
///   図を書くときは黒板を大きくし、先生は黒板の右下に重ねる（#105。`SessionStageLayout`）
/// - 大きな開始・終了ボタン。声の「勉強スタート」「終わり」でも始めて終われる。キーボードは使わない
/// - 子どもが話したことを小さく字幕で出す
/// - 開発用の画面（音声の検証・タイマー・先生ギャラリー・黒板の部品）は右上の虫のボタンから
struct SessionScreen: View {
    @State var model: SessionAppModel
    /// 表示確認用に固定する状態（起動引数 `-sessionPreview`）。nil ならふつうに動かす
    var preview: SessionPreviewState?
    /// 台本の自己テストを画面で流す（起動引数 `-autoSessionDemo`）。あれば準備も自己テストに任せる
    var selfTest: SessionSelfTest?
    @State private var showsDebugMenu = false
    /// 起動引数 `-showSettings` なら設定を開いた状態で始める（設定画面の表示確認用）
    @State private var showsSettings = ProcessInfo.processInfo.arguments.contains("-showSettings")

    var body: some View {
        NavigationStack {
            Group {
                if let coordinator = model.coordinator {
                    SessionContent(
                        coordinator: coordinator, lipSync: model.lipSync, audioStatus: model.audioStatus,
                        permissionNotice: model.permissionNotice, isConfigured: model.services.config != nil
                    )
                } else if let onboarding = model.onboarding {
                    PermissionOnboardingView(onboarding: onboarding, lipSync: model.lipSync)
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
        .modifier(DebugCanvasSize())
        .sheet(isPresented: $showsSettings) {
            SessionSettingsView(preferences: model.preferences)
        }
        // 音声の検証画面はマイクを借りるので、閉じたらセッションのエンジンを作り直す（#75）
        .sheet(isPresented: $showsDebugMenu, onDismiss: { model.reclaimAudio() }) {
            DebugMenuView(config: model.services.config)
        }
        .task {
            if let selfTest {
                await selfTest.run()
            } else if let preview {
                await model.prepare(scriptedInput: ScriptedSpeechInput())
                model.coordinator?.showPreview(preview)
                if preview == .tour { await model.coordinator?.runBoardTour() }
            } else {
                await model.prepare()
            }
        }
        // 机に立てて 25 分使うので、自動ロックで止まらないようにする
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}

/// 起動引数 `-canvasSize 1194x834` なら、画面をその大きさで描いて縮めて見せる。
/// シミュレーターを回せないときに、横置き（机に立てた向き）の配置を確かめるため（#105）
private struct DebugCanvasSize: ViewModifier {
    static let size: CGSize? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-canvasSize"), index + 1 < arguments.count else { return nil }
        let parts = arguments[index + 1].split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        return CGSize(width: parts[0], height: parts[1])
    }()

    func body(content: Content) -> some View {
        if let size = Self.size {
            GeometryReader { geometry in
                let scale = min(geometry.size.width / size.width, geometry.size.height / size.height)
                content
                    .frame(width: size.width, height: size.height)
                    .scaleEffect(scale)
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .background(Color.black)
        } else {
            content
        }
    }
}

struct SessionContent: View {
    let coordinator: StudySessionCoordinator
    let lipSync: LipSyncPlayer
    let audioStatus: String
    let permissionNotice: PermissionNotice?
    let isConfigured: Bool

    /// Worker につながらなかった理由。まだ呼んでいなくても、設定がなければ先に出す
    private var connectionProblem: ConnectionProblem? {
        coordinator.connectionProblem ?? (isConfigured ? nil : .notConfigured)
    }

    var body: some View {
        VStack(spacing: 20) {
            if let permissionNotice {
                ParentNoticeBanner(message: permissionNotice.parentMessage, opensSettings: true)
            }
            if let connectionProblem {
                ParentNoticeBanner(message: connectionProblem.parentMessage)
            }
            stage
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            controls
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
        .background(Color(red: 0.97, green: 0.95, blue: 0.90).ignoresSafeArea())
    }

    // MARK: - 舞台（先生と黒板。#105）

    /// 黒板に何か書いているときは黒板を大きくし、先生は右下に重ねる。書いていないときは先生だけを大きく見せる
    private var stageMode: SessionStageLayout.Mode {
        coordinator.board == nil ? .teacher : .board
    }

    /// 先生と黒板は、それぞれ 1 か所に置いたまま枠だけを動かす（先生の RealityView を作り直さない）
    private var stage: some View {
        GeometryReader { geometry in
            let layout = SessionStageLayout(size: geometry.size, mode: stageMode)
            ZStack(alignment: .topLeading) {
                // 先生だけのときの背景。黒板を書くときは黒板が主役なので消す
                RoundedRectangle(cornerRadius: 28)
                    .fill(LinearGradient(
                        colors: [Color(red: 0.86, green: 0.93, blue: 1.0), Color(red: 0.98, green: 0.96, blue: 0.90)],
                        startPoint: .top, endPoint: .bottom
                    ))
                    .opacity(layout.mode == .teacher ? 1 : 0)
                boardPanel(layout)
                    .frame(width: layout.board.width, height: layout.board.height)
                    .offset(x: layout.board.minX, y: layout.board.minY)
                AvatarView(state: coordinator.avatar.state, lipSync: lipSync, turn: teacherTurn)
                    .frame(width: layout.teacher.width, height: layout.teacher.height)
                    .offset(x: layout.teacher.minX, y: layout.teacher.minY)
                    .allowsHitTesting(false)
                hud(layout)
                caption(layout, stageWidth: geometry.size.width)
                captureOverlay
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .animation(.spring(duration: 0.8, bounce: 0.2), value: layout.mode)
        }
    }

    /// 黒板に書いて話しているときは、黒板の方へ少し体を向ける。聞くときは子どもの方を向く
    private var teacherTurn: Double {
        guard stageMode == .board else { return 0 }
        return coordinator.avatar.state == .talking ? 22 : 8
    }

    // MARK: - 黒板

    /// 黒板の中身は決まった大きさ（`designBase` 以上）で描いて、場所に合わせて縮める（部品の中身が多くてもはみ出さない）。
    /// 先生が重なるところには書かない
    private func boardPanel(_ layout: SessionStageLayout) -> some View {
        BoardSurface(frameWidth: layout.mode == .board ? 14 : 10, showsTray: layout.mode == .board) {
            GeometryReader { geometry in
                let design = SessionStageLayout.designSize(for: geometry.size, base: layout.designBase)
                let scale = geometry.size.width / design.width
                BoardContentView(
                    content: coordinator.board ?? .text(Self.boardHint(phase: coordinator.phase)),
                    insets: Self.occludedInsets(layout.occlusion, board: geometry.size, scale: scale),
                    isSign: coordinator.board == nil
                )
                .boardReveal(coordinator.boardReveal)
                .frame(width: design.width, height: design.height)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            }
        }
        // 図が替わるときは、消して書き直すように入れ替える
        .animation(.easeInOut(duration: 0.45), value: coordinator.board)
    }

    /// 先生が重なるところを避ける余白（設計の座標）。右に空けるか下に空けるか、減る面積が小さい方にする
    static func occludedInsets(_ occlusion: CGSize, board: CGSize, scale: CGFloat) -> EdgeInsets {
        guard occlusion.width > 0, occlusion.height > 0, scale > 0 else { return EdgeInsets() }
        let margin: CGFloat = 12
        let trailingLoss = occlusion.width * board.height
        let bottomLoss = occlusion.height * board.width
        return trailingLoss <= bottomLoss
            ? EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: (occlusion.width + margin) / scale)
            : EdgeInsets(top: 0, leading: 0, bottom: (occlusion.height + margin) / scale, trailing: 0)
    }

    /// 撮影のカウントダウンと「ノートを見てるよ」。先生だけのときも見えるよう、舞台の真ん中に出す
    @ViewBuilder
    private var captureOverlay: some View {
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

    // MARK: - タイマー・しるし・字幕

    /// タイマーは舞台の空いている角に、いまの様子（聞いてる・話してる）は先生の頭の上に出す
    private func hud(_ layout: SessionStageLayout) -> some View {
        ZStack(alignment: .topLeading) {
            if let timer = coordinator.timer {
                FocusTimerView(timer: timer)
                    .scaleEffect(layout.mode == .board ? 0.7 : 0.8, anchor: layout.mode == .board ? .top : .topLeading)
                    .frame(width: layout.hud.width, alignment: layout.mode == .board ? .top : .topLeading)
                    .padding(layout.mode == .board ? 0 : 12)
                    .offset(x: layout.hud.minX, y: layout.hud.minY)
            }
            StateBadge(phase: coordinator.phase, state: coordinator.conversationState, mode: coordinator.sessionMode)
                .fixedSize()
                .position(layout.badgeCenter)
        }
    }

    /// 子どもの発話の字幕。先生の足もとに出す（黒板のときは先生の左へのばす）
    private func caption(_ layout: SessionStageLayout, stageWidth: CGFloat) -> some View {
        // 先生の枠は画面の右へはみ出すことがあるので、右端は舞台の内側にそろえる
        let right = min(layout.teacher.maxX, stageWidth)
        let width = layout.mode == .board ? min(560, right - 12) : layout.teacher.width + 120
        let x = layout.mode == .board ? right - width - 12 : layout.teacher.midX - width / 2
        return CaptionBubble(text: coordinator.caption)
            .frame(width: width, alignment: layout.mode == .board ? .trailing : .center)
            .offset(x: x, y: layout.teacher.maxY - 80)
    }

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
