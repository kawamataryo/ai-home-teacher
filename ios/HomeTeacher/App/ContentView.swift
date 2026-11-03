import SwiftUI

struct ContentView: View {
    let config: AppConfig?

    var body: some View {
        NavigationStack {
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
                NavigationLink("集中・休憩タイマー（確認用）") { FocusTimerPreviewScreen() }
            }
            .padding()
        }
    }
}

#Preview {
    ContentView(config: AppConfig(workerBaseURL: URL(string: "http://localhost:8787")!, familyToken: "preview"))
}
