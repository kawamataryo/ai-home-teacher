import Foundation

/// Info.plist（= Secrets.xcconfig の値）から読む実行時設定。
struct AppConfig: Equatable, Sendable {
    let workerBaseURL: URL
    let familyToken: String

    enum Key {
        static let workerBaseURL = "WorkerBaseURL"
        static let familyToken = "FamilyToken"
    }

    /// 値が空・未展開（`$(...)` のまま）・不正な URL の場合は nil。
    init?(infoDictionary: [String: Any]) {
        guard
            let urlString = Self.value(infoDictionary[Key.workerBaseURL]),
            let url = URL(string: urlString), url.scheme != nil, url.host() != nil,
            let token = Self.value(infoDictionary[Key.familyToken])
        else { return nil }
        self.init(workerBaseURL: url, familyToken: token)
    }

    init(workerBaseURL: URL, familyToken: String) {
        self.workerBaseURL = workerBaseURL
        self.familyToken = familyToken
    }

    static func load(bundle: Bundle = .main) -> AppConfig? {
        AppConfig(infoDictionary: bundle.infoDictionary ?? [:])
    }

    private static func value(_ raw: Any?) -> String? {
        guard let s = (raw as? String)?.trimmingCharacters(in: .whitespaces),
              !s.isEmpty, !s.hasPrefix("$(") else { return nil }
        return s
    }
}
