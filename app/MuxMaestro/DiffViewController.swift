import Cocoa
import WebKit

/// Raised by the Diff pane's Refresh button so the AppDelegate (which owns the
/// selection + services) can recompute the diff for the currently selected
/// session off-main and re-render.
protocol DiffPaneDelegate: AnyObject {
    func diffPaneDidRequestRefresh()
}

/// The third detail segment (M14): a `WKWebView` that renders the selected
/// session's git diff — beautifully, syntax-highlighted — via the vendored,
/// offline `@pierre/diffs` bundle loaded from `file://`. Owns its OWN web view
/// (separate from the Browser pane's), so neither pane disturbs the other's
/// state, matching M12's terminal+browser coexistence.
///
/// A thin top bar carries a Refresh button and a status label
/// ("branch · N files" / "No changes" / "Not a git repository"). The patch is
/// computed off-main by the AppDelegate (`TmuxService.gitDiff`) and handed here
/// via `render(_:header:)`; the contract with the bundle is the two `window`
/// hooks `SidekickDiff.render(patch)` and `SidekickDiff.setTheme('dark'|'light')`.
final class DiffViewController: NSViewController {
    weak var delegate: DiffPaneDelegate?

    private let webView: WKWebView = {
        let wv = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        if #available(macOS 13.3, *) { wv.isInspectable = true }  // devtools, like BrowserVC
        return wv
    }()

    private let refreshButton = NSButton()
    private let statusLabel = NSTextField(labelWithString: "No session selected")

    /// The bundle's `index.html` only finishes loading after a navigation; until
    /// then `evaluateJavaScript` would no-op. We gate renders on `isReady` and
    /// flush the most recent pending patch once the page is up.
    private var isReady = false
    private var pendingPatch: String?
    /// The last patch rendered, replayed on a theme change so the new theme takes
    /// effect without recomputing the diff.
    private var lastPatch = ""
    /// KVO on the view's appearance — NSViewController has no appearance callback,
    /// so we observe `effectiveAppearance` directly to re-theme the bundle.
    private var appearanceObservation: NSKeyValueObservation?

    /// The committed offline bundle's entry point + the directory the web view is
    /// granted read access to (so `file://` can load the sibling JS/CSS).
    private var indexURL: URL? {
        Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "diff")
    }
    private var resourceDir: URL? {
        indexURL?.deletingLastPathComponent()
    }

    override func loadView() {
        let container = NSView()

        refreshButton.image = NSImage(
            systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh diff")
        refreshButton.bezelStyle = .texturedRounded
        refreshButton.target = self
        refreshButton.action = #selector(refresh)
        refreshButton.toolTip = "Recompute the diff for the selected session"
        refreshButton.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let bar = NSStackView(views: [refreshButton, statusLabel])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        bar.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(bar)

        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        container.addSubview(webView)

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: container.topAnchor),
            bar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            webView.topAnchor.constraint(equalTo: bar.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        self.view = container

        // Re-theme when the system appearance flips (NSViewController gets no
        // appearance callback, so observe the view's effectiveAppearance).
        appearanceObservation = container.observe(\.effectiveAppearance) { [weak self] _, _ in
            guard let self, self.isReady else { return }
            self.applyTheme()
        }

        // Load the offline bundle once; renders are evaluated against it after
        // the navigation finishes (see WKNavigationDelegate below).
        if let indexURL, let resourceDir {
            webView.loadFileURL(indexURL, allowingReadAccessTo: resourceDir)
        } else {
            statusLabel.stringValue = "Diff renderer bundle missing"
        }
    }

    // MARK: Rendering

    /// Render `patch` (the combined unified diff) and set the status `header`
    /// (e.g. "main · 3 files" / "No changes" / "Not a git repository"). An empty
    /// patch clears the rendered diff; the header still shows. Safe to call before
    /// the page is ready — the latest patch is flushed once it loads.
    func render(_ patch: String, header: String) {
        lastPatch = patch
        statusLabel.stringValue = header
        if isReady { evaluateRender(patch) } else { pendingPatch = patch }
    }

    /// Pass the patch to the bundle as a JSON-encoded string argument (never
    /// string-interpolated) so any content — quotes, backslashes, `</script>`,
    /// newlines — is delivered verbatim and can't break out of the call.
    private func evaluateRender(_ patch: String) {
        let encoded = (try? JSONEncoder().encode(patch))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        webView.evaluateJavaScript(
            "window.SidekickDiff && window.SidekickDiff.render(\(encoded))", completionHandler: nil)
    }

    /// Match the bundle's theme to the app appearance (dark by default).
    private func applyTheme() {
        let dark = view.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        webView.evaluateJavaScript(
            "window.SidekickDiff && window.SidekickDiff.setTheme('\(dark ? "dark" : "light")')",
            completionHandler: nil)
    }

    @objc private func refresh() { delegate?.diffPaneDidRequestRefresh() }
}

// MARK: - WKNavigationDelegate (bundle ready → flush pending render)

extension DiffViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isReady = true
        applyTheme()
        if let patch = pendingPatch {
            pendingPatch = nil
            evaluateRender(patch)
        }
    }
}
