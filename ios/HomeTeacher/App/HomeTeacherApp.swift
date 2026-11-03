import SwiftUI

@main
struct HomeTeacherApp: App {
    private let config = AppConfig.load()

    var body: some Scene {
        WindowGroup {
            ContentView(config: config)
        }
    }
}
