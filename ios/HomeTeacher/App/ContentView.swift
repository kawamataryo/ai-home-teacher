import SwiftUI

struct ContentView: View {
    let config: AppConfig?

    @State private var path: [String] = SpeechSpikeModel.isAutoRun ? ["spike"] : []

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 24) {
                Text("AI家庭教師")
                    .font(.largeTitle.bold())
                if let config {
                    Label("接続先: \(config.workerBaseURL.absoluteString)", systemImage: "network")
                        .foregroundStyle(.secondary)
                } else {
                    Label("Secrets.xcconfig が未設定です", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                NavigationLink("音声の実機検証（#9）") { SpeechSpikeView() }
                    .buttonStyle(.borderedProminent)
                NavigationLink("集中・休憩タイマー（確認用）") { FocusTimerPreviewScreen() }
                NavigationLink("先生ギャラリー（デバッグ）") { AvatarGalleryView() }
            }
            .padding()
            .navigationDestination(for: String.self) { _ in SpeechSpikeView() }
        }
    }
}

#Preview {
    ContentView(config: AppConfig(workerBaseURL: URL(string: "http://localhost:8787")!, familyToken: "preview"))
}
