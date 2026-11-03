import SwiftUI

/// 開発用の画面への入り口。学習セッション画面の右上（虫のボタン）から開く。
struct DebugMenuView: View {
    let config: AppConfig?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("接続先") {
                    if let config {
                        Label(config.workerBaseURL.absoluteString, systemImage: "network")
                    } else {
                        Label("Secrets.xcconfig が未設定です", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                Section("確認用の画面") {
                    NavigationLink("音声の実機検証（#9）") { SpeechSpikeView() }
                    NavigationLink("集中・休憩タイマー") { FocusTimerPreviewScreen() }
                    NavigationLink("先生ギャラリー") { AvatarGalleryView() }
                    NavigationLink("黒板の部品") { BoardGallery() }
                }
            }
            .navigationTitle("開発用メニュー")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }
}
