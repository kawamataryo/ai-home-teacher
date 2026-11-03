import SwiftUI

@main
struct HomeTeacherApp: App {
    private let config = AppConfig.load()

    var body: some Scene {
        WindowGroup {
            ContentView(config: config)
                // 定型句の音声を初回に作っておく（#12）
                .task { await PhraseCache.warmUp(config: config) }
        }
    }
}
