import Cocoa
import WebKit

/// The right-sidebar web preview for a link hovered in the terminal. It keeps
/// its own persistent cookie store, so a site signed in here stays signed in
/// across launches and stays apart from the Diff and Help web views.
final class LinkPreviewViewController: NSViewController {
    /// Close was clicked. The owner hides the pane.
    var onClose: (() -> Void)?

    /// Fixed so the store, and its cookies, survive relaunches.
    private static let storeID = UUID(uuidString: "6F1C2E1A-4B7D-4C1E-9A55-2D7E0B3C8F10")!

    private lazy var webView: WKWebView = {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: Self.storeID)
        // Some sign-in pages refuse a user agent without the Safari token.
        config.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        return web
    }()

    private let titleLabel = NSTextField(labelWithString: "")
    private let backButton = NSButton()
    private let reloadButton = NSButton()
    private let openButton = NSButton()
    private let closeButton = NSButton()
    private var observations: [NSKeyValueObservation] = []

    override func loadView() {
        let container = NSView()

        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = SidebarPalette.text
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        configure(backButton, symbol: "chevron.left", tip: "Back", action: #selector(goBack))
        configure(reloadButton, symbol: "arrow.clockwise", tip: "Reload", action: #selector(reload))
        configure(openButton, symbol: "safari", tip: "Open in Browser", action: #selector(openInBrowser))
        configure(closeButton, symbol: "xmark", tip: "Close", action: #selector(close))
        backButton.isEnabled = false

        let header = NSStackView(views: [backButton, titleLabel, reloadButton, openButton, closeButton])
        header.orientation = .horizontal
        header.spacing = 6
        header.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        header.translatesAutoresizingMaskIntoConstraints = false

        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(header)
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: container.topAnchor),
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 26),
            webView.topAnchor.constraint(equalTo: header.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        observations = [
            webView.observe(\.title) { [weak self] _, _ in self?.updateTitle() },
            webView.observe(\.url) { [weak self] _, _ in self?.updateTitle() },
            webView.observe(\.canGoBack) { [weak self] web, _ in self?.backButton.isEnabled = web.canGoBack },
        ]
        self.view = container
    }

    private func configure(_ button: NSButton, symbol: String, tip: String, action: Selector) {
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        button.contentTintColor = SidebarPalette.muted
        button.toolTip = tip
        button.target = self
        button.action = action
        button.setContentHuggingPriority(.required, for: .horizontal)
    }

    /// The URL last asked for, so hovering the same link again does not reload.
    private var requested: URL?

    /// Show `url`. A no-op when it is already the page asked for or on screen.
    func load(_ url: URL) {
        _ = view
        guard url != requested, url != webView.url else { return }
        requested = url
        titleLabel.stringValue = url.host ?? url.absoluteString
        webView.load(URLRequest(url: url))
    }

    private func updateTitle() {
        let title = webView.title ?? ""
        titleLabel.stringValue = title.isEmpty ? (webView.url?.host ?? "") : title
        titleLabel.toolTip = webView.url?.absoluteString
    }

    @objc private func goBack() { webView.goBack() }
    @objc private func reload() { webView.reload() }
    @objc private func close() { onClose?() }

    @objc private func openInBrowser() {
        guard let url = webView.url ?? requested else { return }
        NSWorkspace.shared.open(url)
    }

    /// Schemes a page may load here. `about`, `blob` and `data` serve frames
    /// inside a web page; a top-level link to anything else goes to the system.
    private static let pageSchemes: Set<String> = ["http", "https", "about", "blob", "data"]

    private static func isWeb(_ url: URL?) -> Bool {
        guard let scheme = url?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}

extension LinkPreviewViewController: WKNavigationDelegate, WKUIDelegate {
    /// Only web pages load here. Other schemes (mailto:, app links) go to the system.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        if let scheme = url?.scheme?.lowercased(), Self.pageSchemes.contains(scheme) {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        if let url, navigationAction.navigationType == .linkActivated { NSWorkspace.shared.open(url) }
    }

    /// A popup or `target=_blank` link (an OAuth sign-in, say) loads in this view.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url, Self.isWeb(url) {
            webView.load(URLRequest(url: url))
        }
        return nil
    }
}
