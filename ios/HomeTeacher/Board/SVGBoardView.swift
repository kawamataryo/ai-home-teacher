import SwiftUI
import WebKit

/// render_svg の図を、閉じた WKWebView で表示する。
struct SVGBoardView: View {
    let board: SVGBoard

    var body: some View {
        VStack(spacing: 16) {
            SVGWebView(svg: board.svg)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !board.caption.isEmpty {
                Text(board.caption)
                    .font(Chalk.font(28, weight: .semibold))
                    .foregroundStyle(Chalk.white)
                    .multilineTextAlignment(.center)
            }
        }
    }
}

/// SVG を表示するための、外に出られない WKWebView の設定。
/// - JavaScript 無効（WKWebpagePreferences）
/// - CSP で script・外部読み込みを禁止（data: の画像とインライン CSS だけ）
/// - コンテンツブロッカーで about: / data: 以外の読み込みを遮断
/// - 遷移は about: / data: だけ許可（WKNavigationDelegate）
/// - Cookie などを残さない（nonPersistent）
enum SVGSandbox {
    static let csp = "default-src 'none'; style-src 'unsafe-inline'; img-src data:"

    /// about: と data: 以外をすべて遮断するルール（url-filter は | の選択に対応していないので分ける）。
    static let contentRules = """
        [
          {"trigger": {"url-filter": ".*"}, "action": {"type": "block"}},
          {"trigger": {"url-filter": "^about:"}, "action": {"type": "ignore-previous-rules"}},
          {"trigger": {"url-filter": "^data:"}, "action": {"type": "ignore-previous-rules"}}
        ]
        """

    static func html(svg: String) -> String {
        """
        <!doctype html><html><head>\
        <meta http-equiv="Content-Security-Policy" content="\(csp)">\
        <meta name="viewport" content="width=device-width,initial-scale=1">\
        <style>html,body{margin:0;height:100%;background:transparent;overflow:hidden}\
        body{display:flex;align-items:center;justify-content:center;font-family:"Hiragino Maru Gothic ProN",-apple-system,sans-serif}\
        svg{width:100%;height:100%}</style>\
        </head><body>\(svg)</body></html>
        """
    }

    /// 遷移してよい URL か。
    static func allowsNavigation(to url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return scheme == "about" || scheme == "data"
    }

    @MainActor static func makeConfiguration(ruleList: WKContentRuleList?) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        config.suppressesIncrementalRendering = true
        if let ruleList { config.userContentController.add(ruleList) }
        return config
    }

    @MainActor private static var cachedRuleList: WKContentRuleList?

    /// コンテンツブロッカーを用意する（一度だけコンパイルする）。
    @MainActor static func ruleList() async throws -> WKContentRuleList {
        if let cachedRuleList { return cachedRuleList }
        guard let store = WKContentRuleListStore.default() else { throw SandboxError.noRuleStore }
        let list = try await store.compileContentRuleList(forIdentifier: "board-svg-sandbox", encodedContentRuleList: contentRules)
        guard let list else { throw SandboxError.noRuleStore }
        cachedRuleList = list
        return list
    }

    enum SandboxError: Error { case noRuleStore }

    /// 設定済みの WKWebView を作って HTML を読み込む。ルールの用意が終わってから読み込むので、最初の読み込みも遮断の対象になる。
    @MainActor static func makeWebView(navigationDelegate: WKNavigationDelegate) async throws -> WKWebView {
        let config = makeConfiguration(ruleList: try await ruleList())
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = navigationDelegate
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        return web
    }

    /// 遷移を about: / data: に限る delegate。
    final class NavigationGuard: NSObject, WKNavigationDelegate {
        var onFinish: (@MainActor () -> Void)?

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
            preferences.allowsContentJavaScript = false
            return (SVGSandbox.allowsNavigation(to: navigationAction.request.url) ? .allow : .cancel, preferences)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onFinish?()
        }
    }
}

/// SwiftUI から使う WKWebView。ルールの用意を待ってから中に差し込む。
struct SVGWebView: UIViewRepresentable {
    let svg: String

    @MainActor final class Coordinator {
        let guardian = SVGSandbox.NavigationGuard()
        var web: WKWebView?
        var loadedSVG: String?
        var task: Task<Void, Never>?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        container.backgroundColor = .clear
        let coordinator = context.coordinator
        coordinator.task = Task { @MainActor in
            guard let web = try? await SVGSandbox.makeWebView(navigationDelegate: coordinator.guardian) else { return }
            web.frame = container.bounds
            web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(web)
            coordinator.web = web
            load(svg, in: coordinator)
        }
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        load(svg, in: context.coordinator)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.task?.cancel()
    }

    @MainActor private func load(_ svg: String, in coordinator: Coordinator) {
        guard let web = coordinator.web, coordinator.loadedSVG != svg else { return }
        coordinator.loadedSVG = svg
        web.loadHTMLString(SVGSandbox.html(svg: svg), baseURL: nil)
    }
}
