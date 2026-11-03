import Foundation
import Testing
@testable import HomeTeacher

struct AppConfigTests {
    @Test func 正しい値から設定を読める() throws {
        let config = try #require(AppConfig(infoDictionary: [
            "WorkerBaseURL": "https://example.workers.dev",
            "FamilyToken": "token-123",
        ]))
        #expect(config.workerBaseURL == URL(string: "https://example.workers.dev"))
        #expect(config.familyToken == "token-123")
        // 声の設定がなければ ElevenLabs
        #expect(config.ttsProvider == .elevenlabs)
    }

    @Test func 先生の声の設定を読める() throws {
        let base = ["WorkerBaseURL": "https://example.workers.dev", "FamilyToken": "t"]
        #expect(AppConfig(infoDictionary: base.merging(["TTSProvider": "azure"]) { $1 })?.ttsProvider == .azure)
        #expect(AppConfig(infoDictionary: base.merging(["TTSProvider": "$(TTS_PROVIDER)"]) { $1 })?.ttsProvider == .elevenlabs)
    }

    @Test(arguments: [
        [String: String](),
        ["WorkerBaseURL": "", "FamilyToken": "t"],
        ["WorkerBaseURL": "$(WORKER_BASE_URL)", "FamilyToken": "t"],
        ["WorkerBaseURL": "not a url", "FamilyToken": "t"],
        ["WorkerBaseURL": "https://example.com", "FamilyToken": ""],
    ])
    func 未設定や不正な値ならnil(info: [String: String]) {
        #expect(AppConfig(infoDictionary: info) == nil)
    }
}
