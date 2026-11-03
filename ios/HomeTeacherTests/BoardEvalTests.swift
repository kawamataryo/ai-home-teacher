import Foundation
import SwiftUI
import Testing
import UIKit
@testable import HomeTeacher

/// 黒板の評価（#70）。評価スクリプト（evals/boards.mjs）とアプリで、送る本文とツールを1か所（Swift）にそろえる。
///
/// - `evals/fixtures/board_tools.json`：分析（Sonnet）に送る本文のひな形。写真のかわりに問題の文字を入れて送る
///   `TEST_RUNNER_BOARD_EXPORT=1 xcodebuild test ...` で書き出す。ふだんは Swift と食い違っていないかだけ確かめる
/// - `TEST_RUNNER_BOARD_EVAL=before`（または after）で、`evals/fixtures/boards/<phase>/*.json` の図を
///   `docs/screenshots/boards-eval/<phase>/` に PNG で書き出す
@MainActor
struct BoardEvalTests {
    static let repoRoot = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let fixtureURL = repoRoot.appending(path: "evals/fixtures/board_tools.json")

    /// 分析のリクエストのひな形。画像の中身は空にする（評価スクリプトが問題の文字に置きかえる）。
    static func analyzerTemplate() throws -> JSONValue {
        let client = WorkerClient(baseURL: URL(string: "https://example.workers.dev")!, familyToken: "t", transport: MockTransport(body: ""))
        let body = try ProblemAnalyzer(client: client).makeRequestBody(jpegData: Data(), conversation: [], imageID: "photo_1")
        return .object(["analyzer_request": body])
    }

    static func exportedData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        return try encoder.encode(try analyzerTemplate())
    }

    @Test func 評価用のツール定義はSwiftと同じ() throws {
        let data = try Self.exportedData()
        if ProcessInfo.processInfo.environment["BOARD_EXPORT"] == "1" {
            try FileManager.default.createDirectory(at: Self.fixtureURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: Self.fixtureURL)
            return
        }
        let saved = try Data(contentsOf: Self.fixtureURL)
        let decodedSaved = try JSONDecoder().decode(JSONValue.self, from: saved)
        let decodedNow = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decodedSaved == decodedNow, "evals/fixtures/board_tools.json が古い。TEST_RUNNER_BOARD_EXPORT=1 で書き出し直す")
    }

    /// 評価スクリプトが保存した1問分。
    struct EvalFixture: Decodable {
        struct Board: Decodable {
            var name: String
            var input: JSONValue
        }
        var id: String
        var boards: [Board]
        var analysis: JSONValue?
    }

    /// 評価の図を PNG にする。アプリと同じく「最初の図。なければ問題の要約」を `<id>.png`、2枚目以降を `<id>-2.png` …にする。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BOARD_EVAL"] != nil))
    func 評価の図を書き出す() async throws {
        let phase = try #require(ProcessInfo.processInfo.environment["BOARD_EVAL"])
        let source = Self.repoRoot.appending(path: "evals/fixtures/boards/\(phase)")
        let out = Self.repoRoot.appending(path: "docs/screenshots/boards-eval/\(phase)")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let files = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(!files.isEmpty)
        for file in files {
            let fixture = try JSONDecoder().decode(EvalFixture.self, from: Data(contentsOf: file))
            var contents = fixture.boards.map { BoardTools.content(toolName: $0.name, input: $0.input) }
            if contents.isEmpty {
                contents = [.text(fixture.analysis?["problem_summary"]?.stringValue ?? "（分析なし）")]
            }
            for (i, content) in contents.enumerated() {
                let name = i == 0 ? "\(fixture.id).png" : "\(fixture.id)-\(i + 1).png"
                let image = try await Self.capture(content)
                try #require(image.pngData()).write(to: out.appending(path: name))
            }
        }
    }

    /// 画面と同じ大きさ（SessionContent.boardDesignSize と同じ 1100×860）で描く。SVG は WKWebView なので窓に載せて撮る。
    static func capture(_ content: BoardContent) async throws -> UIImage {
        let size = CGSize(width: 1100, height: 860)
        if case .svg = content {
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(origin: .zero, size: size)
            window.rootViewController = UIHostingController(rootView: BoardView(content: content)
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, .dark))
            window.isHidden = false
            defer { window.isHidden = true }
            // ルールのコンパイル・読み込み・CSS アニメが終わるのを待つ
            try await Task.sleep(for: .seconds(3.5))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
        }
        let view = BoardView(content: content)
            .frame(width: size.width, height: size.height)
            .environment(\.boardAnimated, false)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return try #require(renderer.uiImage)
    }
}
