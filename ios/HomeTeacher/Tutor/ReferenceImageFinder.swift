import Foundation

/// 黒板に出す本物の写真（#116）。写真は端末のメモリにだけ置く。
struct ReferenceImage: Equatable, Hashable, Sendable {
    var query: String
    var caption: String
    /// 作者とライセンス
    var credit: String
    var data: Data
}

/// show_reference_image のツール。定義は prompts/tools/show_reference_image.json。
enum ReferenceImageTool {
    static let name = "show_reference_image"
    /// 写真を探す先（調べものカードに出す）
    static let site = "ja.wikipedia.org"

    /// 見つからなかったときの tool_result
    static let notFoundText = "ぴったりの写真は見つかりませんでした。写真にはふれずに、言葉で説明するか show_board で描いてください。"

    /// 探す言葉が問題の答えだったときの tool_result
    static let answerBlockedText = "その写真は問題の答えになるので、出しませんでした。写真にはふれずに、ヒントを出して子どもに考えてもらってください。"

    static func parse(_ input: JSONValue) -> (query: String, caption: String)? {
        guard let query = input["query"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty else {
            return nil
        }
        return (query, input["caption"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }
}

protocol ReferenceImageFinding: Sendable {
    /// 写真を探す。見つからなければ nil（失敗も nil。確かめられなかった写真は子どもに見せない）
    func find(query: String, caption: String) async -> ReferenceImage?
}

/// ウィキペディア日本語版から、自由ライセンスの写真を探す。
///
/// 検索語はモデルが作る名詞で、端末から直接ウィキペディアに送る。
/// 候補はモデル（Haiku）に見せて、内容が合っているか・小 5 に見せてよいかを確かめてから出す（確かめられなければ出さない）。
struct ReferenceImageFinder: ReferenceImageFinding {
    static let apiURL = URL(string: "https://ja.wikipedia.org/w/api.php")!
    /// Wikimedia は連絡先のわかる User-Agent を求めている
    static let userAgent = "HomeTeacher/1.0 (https://github.com/kawamataryo/ai-home-teacher)"
    /// サムネイルの幅。Wikimedia が用意している大きさの 1 つ
    static let thumbnailWidth = 960
    static let maxCandidates = 3
    static let acceptedMediaTypes: Set<String> = ["image/jpeg", "image/png", "image/webp", "image/gif"]

    let client: WorkerClient
    var library = PromptLibrary()
    var transport: any HTTPTransport = URLSessionTransport()

    struct Candidate: Equatable, Sendable {
        let pageTitle: String
        let fileName: String
        let thumbnailURL: URL
    }

    func find(query: String, caption: String) async -> ReferenceImage? {
        guard let candidates = try? await searchCandidates(query: query) else { return nil }
        for candidate in candidates.prefix(Self.maxCandidates) {
            if Task.isCancelled { return nil }
            guard let (data, mediaType) = try? await download(candidate.thumbnailURL),
                  (try? await isSuitable(data: data, mediaType: mediaType, query: query)) == true
            else { continue }
            let credit = (try? await credit(for: candidate)) ?? Self.fallbackCredit(pageTitle: candidate.pageTitle)
            return ReferenceImage(query: query, caption: caption.isEmpty ? candidate.pageTitle : caption, credit: credit, data: data)
        }
        return nil
    }

    // MARK: - ウィキペディア

    func searchCandidates(query: String) async throws -> [Candidate] {
        let data = try await get(items: [
            URLQueryItem(name: "generator", value: "search"),
            URLQueryItem(name: "gsrsearch", value: query),
            URLQueryItem(name: "gsrlimit", value: "6"),
            URLQueryItem(name: "gsrnamespace", value: "0"),
            URLQueryItem(name: "prop", value: "pageimages"),
            URLQueryItem(name: "piprop", value: "thumbnail|name"),
            URLQueryItem(name: "pithumbsize", value: String(Self.thumbnailWidth)),
            // 自由ライセンスの画像だけ
            URLQueryItem(name: "pilicense", value: "free"),
        ])
        return Self.parseCandidates(data)
    }

    static func parseCandidates(_ data: Data) -> [Candidate] {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .array(let pages)? = json["query"]?["pages"]
        else { return [] }
        let ordered = pages.sorted { (number($0["index"]) ?? .infinity) < (number($1["index"]) ?? .infinity) }
        return ordered.compactMap { page in
            guard let title = page["title"]?.stringValue,
                  let file = page["pageimage"]?.stringValue,
                  let source = page["thumbnail"]?["source"]?.stringValue,
                  let url = URL(string: source)
            else { return nil }
            return Candidate(pageTitle: title, fileName: file, thumbnailURL: url)
        }
    }

    private static func number(_ value: JSONValue?) -> Double? {
        if case .number(let n)? = value { return n }
        return nil
    }

    private func download(_ url: URL) async throws -> (Data, String) {
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await transport.data(for: request)
        let mediaType = (response.value(forHTTPHeaderField: "Content-Type") ?? "")
            .split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        guard (200..<300).contains(response.statusCode), Self.acceptedMediaTypes.contains(mediaType) else {
            throw URLError(.badServerResponse)
        }
        return (data, mediaType)
    }

    private func credit(for candidate: Candidate) async throws -> String {
        let data = try await get(items: [
            URLQueryItem(name: "titles", value: "File:\(candidate.fileName)"),
            URLQueryItem(name: "prop", value: "imageinfo"),
            URLQueryItem(name: "iiprop", value: "extmetadata"),
            URLQueryItem(name: "iiextmetadatafilter", value: "Artist|LicenseShortName"),
        ])
        return Self.parseCredit(data) ?? Self.fallbackCredit(pageTitle: candidate.pageTitle)
    }

    static func parseCredit(_ data: Data) -> String? {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .array(let pages)? = json["query"]?["pages"],
              case .array(let infos)? = pages.first?["imageinfo"],
              let metadata = infos.first?["extmetadata"]
        else { return nil }
        let artist = metadata["Artist"]?["value"]?.stringValue.map(strippingTags) ?? ""
        let license = metadata["LicenseShortName"]?["value"]?.stringValue.map(strippingTags) ?? ""
        let parts = [artist, license].filter { !$0.isEmpty }
        return parts.isEmpty ? nil : "写真：" + parts.joined(separator: " / ") + "（ウィキメディア・コモンズ）"
    }

    static func fallbackCredit(pageTitle: String) -> String {
        "写真：ウィキペディア「\(pageTitle)」より"
    }

    static func strippingTags(_ html: String) -> String {
        html.replacing(/<[^>]+>/, with: "")
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func get(items: [URLQueryItem]) async throws -> Data {
        var components = URLComponents(url: Self.apiURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "formatversion", value: "2"),
        ] + items
        guard let url = components?.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else { throw URLError(.badServerResponse) }
        return data
    }

    // MARK: - 確認

    /// 写真を Haiku に見せて確かめる
    private func isSuitable(data: Data, mediaType: String, query: String) async throws -> Bool {
        let body = JSONValue.object([
            "model": .string(ClaudeModel.haiku.rawValue),
            "max_tokens": .number(16),
            "stream": .bool(false),
            "thinking": MessagesRequest.thinkingDisabled,
            "messages": .array([
                .object([
                    "role": .string(ChatRole.user.rawValue),
                    "content": .array([
                        .object([
                            "type": .string("image"),
                            "source": .object([
                                "type": .string("base64"),
                                "media_type": .string(mediaType),
                                "data": .string(data.base64EncodedString()),
                            ]),
                        ]),
                        .object([
                            "type": .string("text"),
                            "text": .string(try library.load(.referenceImageCheck, variables: ["query": query])),
                        ]),
                    ]),
                ]),
            ]),
        ])
        let response = try await client.postJSON(path: TeacherBrain.claudePath, body: body.jsonData())
        return Self.parseVerdict(response)
    }

    /// `OK` だけのときに true。読めないときは見せない
    static func parseVerdict(_ data: Data) -> Bool {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .array(let blocks)? = json["content"]
        else { return false }
        let text = blocks.compactMap { $0["text"]?.stringValue }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return text.hasPrefix("OK") && !text.contains("NG")
    }
}
