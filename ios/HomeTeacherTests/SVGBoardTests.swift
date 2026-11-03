import Foundation
import SwiftUI
import Testing
import WebKit
@testable import HomeTeacher

struct SVGSanitizerTests {
    private func sanitized(_ body: String) throws -> SVGSanitizer.Sanitized {
        let svg = #"<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 10 10">"# + body + "</svg>"
        return try SVGSanitizer.sanitize(svg).get()
    }

    @Test(arguments: [
        ("<script>alert(1)</script>", "alert"),
        ("<SCRIPT>alert(1)</SCRIPT>", "alert"),
        (#"<foreignObject><div xmlns="http://www.w3.org/1999/xhtml">x</div></foreignObject>"#, "div"),
        (#"<image href="https://example.com/a.png"/>"#, "example.com"),
        (#"<a href="javascript:alert(1)"><text>x</text></a>"#, "javascript"),
        (#"<use href="https://example.com/s.svg#x"/>"#, "example.com"),
        (#"<use xlink:href="http://example.com/s.svg#x"/>"#, "example.com"),
        (#"<rect onclick="alert(1)" onload="x()" width="1" height="1"/>"#, "alert"),
        (#"<style>@import url(https://example.com/a.css);</style>"#, "example.com"),
        (#"<style>rect{fill:url(https://example.com/p.svg)}</style>"#, "example.com"),
        (#"<style>rect{background:\75rl(https://example.com)}</style>"#, "example.com"),
        (#"<rect style="fill:url('https://example.com/p')" width="1" height="1"/>"#, "example.com"),
        (#"<rect fill="url(https://example.com/p)" width="1" height="1"/>"#, "example.com"),
        (#"<animate attributeName="href" to="javascript:alert(1)"/>"#, "javascript"),
        (#"<set attributeName="onclick" to="alert(1)"/>"#, "alert"),
        (#"<iframe src="https://example.com"></iframe>"#, "example.com"),
        (#"<style>&#64;import "https://example.com/a.css";</style>"#, "example.com"),
        (#"<style>rect{fill:u&#114;l(https://example.com/p)}</style>"#, "example.com"),
        (#"<style><![CDATA[@imp]]>ort url(https://example.com/a.css);</style>"#, "example.com"),
    ])
    func 危険な部分は取り除かれる(body: String, forbidden: String) throws {
        let result = try sanitized(body)
        #expect(!result.svg.contains(forbidden), "\(result.svg)")
        #expect(!result.svg.lowercased().contains("<script"))
        #expect(!result.svg.contains(" on"), "イベント属性が残った: \(result.svg)")
        #expect(!result.removed.isEmpty)
    }

    @Test func ルートのsvgのonloadも取り除かれる() throws {
        let result = try SVGSanitizer.sanitize(#"<svg onload="alert(1)" viewBox="0 0 1 1"><rect width="1" height="1"/></svg>"#).get()
        #expect(!result.svg.contains("onload"))
        #expect(result.svg.contains("<rect"))
    }

    @Test(arguments: [
        #"<!DOCTYPE svg [<!ENTITY a "aaaa">]><svg viewBox="0 0 1 1"><text>&a;</text></svg>"#,
        #"<svg viewBox="0 0 1 1"><rect></svg>"#,
        "ただの文字",
        #"<html><body><svg/></body></html>"#,
        "",
    ])
    func 読めないSVGは受け付けない(svg: String) {
        if case .success(let s) = SVGSanitizer.sanitize(svg) {
            Issue.record("受け付けてしまった: \(s.svg)")
        }
    }

    @Test func 大きすぎるSVGは受け付けない() {
        let big = "<svg>" + String(repeating: "<g></g>", count: 40_000) + "</svg>"
        #expect(SVGSanitizer.sanitize(big) == .failure(.tooLarge))
    }

    @Test func 文書内の参照とCSSアニメは残る() throws {
        let result = try sanitized(#"""
            <defs><linearGradient id="g"><stop offset="0" stop-color="#fff"/></linearGradient><path id="p" d="M0 0L1 1"/></defs>
            <style>.a{animation:k 1s infinite}@keyframes k{to{opacity:.5}}</style>
            <rect class="a" fill="url(#g)" width="5" height="5"/><use href="#p"/><text x="1" y="2">A &amp; B</text>
            """#)
        #expect(result.removed.isEmpty, "\(result.removed)")
        #expect(result.svg.contains(#"fill="url(#g)""#))
        #expect(result.svg.contains(##"href="#p""##))
        #expect(result.svg.contains("@keyframes"))
        #expect(result.svg.contains("A &amp; B"))
    }

    @Test func サンプルSVGはそのまま描ける() throws {
        let result = try SVGSanitizer.sanitize(BoardSamples.svg).get()
        #expect(result.removed.isEmpty, "\(result.removed)")
        #expect(result.svg.contains("<polygon"))
    }
}

struct RenderSVGToolTests {
    @Test func ツール定義はstrictでsvgとcaptionを持つ() {
        let tool = BoardTools.renderSVG
        #expect(tool["name"] == .string("render_svg"))
        #expect(tool["strict"] == .bool(true))
        #expect(tool["input_schema"]?["additionalProperties"] == .bool(false))
        #expect(tool["input_schema"]?["required"] == .array([.string("svg"), .string("caption")]))
        #expect(BoardTools.all.compactMap { $0["name"]?.stringValue } == ["show_board", "render_svg"])
    }

    @Test func サンプルはSVGの黒板になる() {
        guard case .svg(let board) = BoardSamples.svgContent else {
            Issue.record("SVG になっていない")
            return
        }
        #expect(board.caption.contains("三角形"))
    }

    @Test func 危険なSVGは無害化されて届く() throws {
        let input = try JSONEncoder().encode(RenderSVGInput(svg: #"<svg viewBox="0 0 1 1"><script>x()</script><circle r="1"/></svg>"#, caption: ""))
        guard case .svg(let board) = BoardTools.content(toolName: "render_svg", input: input) else {
            Issue.record("SVG になっていない")
            return
        }
        #expect(!board.svg.contains("script"))
        #expect(board.svg.contains("<circle"))
    }

    @Test func 読めないSVGは説明の文字だけ出す() throws {
        let input = try JSONEncoder().encode(RenderSVGInput(svg: "<svg><g></svg>", caption: "角度に注目"))
        #expect(BoardTools.content(toolName: "render_svg", input: input) == .text("角度に注目"))
        #expect(BoardTools.content(toolName: "render_svg", input: Data(#"{"caption":"x"}"#.utf8)) == .text("x"))
    }
}

@MainActor
struct SVGSandboxTests {
    @Test(arguments: [
        ("about:blank", true), ("data:image/svg+xml,<svg/>", true),
        ("https://example.com", false), ("http://localhost:8787", false), ("file:///etc/hosts", false),
        ("javascript:alert(1)", false), ("blob:https://example.com/x", false),
    ])
    func 遷移はaboutとdataだけ(url: String, allowed: Bool) {
        #expect(SVGSandbox.allowsNavigation(to: URL(string: url)) == allowed)
    }

    @Test func HTMLの先頭でCSPを宣言する() {
        let html = SVGSandbox.html(svg: "<svg/>")
        let head = try! #require(html.range(of: "<head>"))
        #expect(html[head.upperBound...].hasPrefix(#"<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:">"#))
    }

    @Test func 設定でJavaScriptが無効() async throws {
        let config = SVGSandbox.makeConfiguration(ruleList: try await SVGSandbox.ruleList())
        #expect(config.defaultWebpagePreferences.allowsContentJavaScript == false)
        #expect(!config.websiteDataStore.isPersistent)
    }

    /// 無害化を通さない HTML を直接入れても、ページ内の script は動かない。
    @Test func サンドボックスではscriptが動かない() async throws {
        let guardian = SVGSandbox.NavigationGuard()
        let web = try await SVGSandbox.makeWebView(navigationDelegate: guardian)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            guardian.onFinish = { c.resume() }
            web.loadHTMLString(SVGSandbox.html(svg: "<script>document.title='pwned'</script><svg onload=\"document.title='pwned2'\"/>"),
                               baseURL: nil)
        }
        let title = try await web.evaluateJavaScript("document.title") as? String
        #expect(title == "")
    }

    /// `TEST_RUNNER_BOARD_SNAPSHOT=1` のときだけ docs/screenshots/board-svg.png を書き出す。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BOARD_SNAPSHOT"] == "1"))
    func SVGの黒板のスクリーンショットを書き出す() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1100, height: 720)
        let host = UIHostingController(rootView: BoardView(content: BoardSamples.svgContent)
            .frame(width: 1100, height: 720)
            .environment(\.colorScheme, .dark))
        window.rootViewController = host
        window.isHidden = false
        // ルールのコンパイル・読み込み・CSS アニメ（1.6 秒）が終わるのを待つ
        try await Task.sleep(for: .seconds(3.5))
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: {
            let f = UIGraphicsImageRendererFormat()
            f.scale = 2
            return f
        }()).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let dir = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "docs/screenshots")
        try #require(image.pngData()).write(to: dir.appending(path: "board-svg.png"))
        window.isHidden = true
    }
}
