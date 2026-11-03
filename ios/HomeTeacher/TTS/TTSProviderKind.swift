import Foundation

/// 先生の声に使う TTS。Secrets.xcconfig の `TTS_PROVIDER`（azure / elevenlabs）で選ぶ。書かなければ Azure（#98 で費用を見て切り替えた）
enum TTSProviderKind: String, CaseIterable, Equatable, Sendable {
    case elevenlabs
    case azure

    static let `default` = TTSProviderKind.azure

    /// Info.plist の値から。空・未展開・知らない名前なら既定
    init(setting: String?) {
        let value = setting?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        self = TTSProviderKind(rawValue: value) ?? .default
    }

    /// Worker 経由の TTS を作る。`identifier` は `TTSProvider.identifier` と同じ
    @MainActor
    func makeProvider(client: WorkerClient) -> any TTSProvider {
        switch self {
        case .elevenlabs: ElevenLabsTTSProvider(client: client)
        case .azure: AzureTTSProvider(client: client)
        }
    }
}
