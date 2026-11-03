import SwiftUI

@main
struct HomeTeacherApp: App {
    @State private var services = AppServices(config: AppConfig.load())

    var body: some Scene {
        WindowGroup {
            ContentView(services: services)
                // 定型句の音声を初回に作っておく（#12）
                .task { await PhraseCache.warmUp(config: services.config) }
                // 起動時に同期し、つながったらまた同期する（#28）
                .task { await services.syncAtLaunch() }
        }
    }
}
