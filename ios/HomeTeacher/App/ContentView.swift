import SwiftUI

/// 最初の画面。ふだんは学習セッション画面。
/// 起動引数で検証用の画面に切り替える（`-autoSpike` などは #9 の検証画面、`-autoSession` はセッションの自己テスト（`-autoSessionDemo` はそれをセッション画面で）、`-autoWatch` は見守りの自己テスト）。
struct ContentView: View {
    let services: AppServices

    var body: some View {
        if AppServices.isTestHost {
            // ユニットテストのホストとして起動したときは、マイクを開かない
            Color.clear
        } else if ProcessInfo.processInfo.arguments.contains("-avatarGallery") {
            // 確認用：先生ギャラリーをそのまま開く（スクリーンショット用）
            NavigationStack { AvatarGalleryView() }
        } else if SpeechSpikeModel.isAutoRun {
            NavigationStack { SpeechSpikeView() }
        } else if WatchOverSelfTest.isEnabled {
            WatchOverSelfTestView(services: services)
        } else if SessionSelfTest.isDemoEnabled {
            SessionSelfTestDemoView(services: services)
        } else if SessionSelfTest.isEnabled {
            SessionSelfTestView(services: services)
        } else {
            SessionScreen(
                model: SessionAppModel(services: services, permissions: FixedPermissions.fromLaunchArguments() ?? SystemPermissions()),
                preview: SessionPreviewState.fromLaunchArguments()
            )
        }
    }
}
