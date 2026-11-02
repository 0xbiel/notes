import AppKit
import SwiftUI
import WebKit
import LectureCore

struct RenderedMarkdownHTML {
    let block: MarkdownHTMLBlock
    let view: MarkdownHTMLView
    let size: NSSize
    var foldedRange: NSRange { NSRange(location: block.range.location + 1, length: block.range.length - 1) }
}

/// Only a bounded height crosses the frame boundary. HTML has the same opaque
/// origin, nonpersistent storage and navigation policy as standalone views.
@MainActor final class MarkdownHTMLView: NSView, WKScriptMessageHandler {
    let webView: WKWebView
    private let coordinator = NotebookHTMLSurface.Coordinator()
    private var loadedSource: String?
    private(set) var contentHeight: CGFloat = 24
    private(set) var hasMeasuredContent = false
    var heightChanged: (() -> Void)?
    override var isFlipped: Bool { true }
    init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: .zero)
        configuration.userContentController.add(WeakHeightHandler(self), name: "notebookHTMLHeight")
        configuration.userContentController.addUserScript(.init(source: """
        window.addEventListener('message', event => {
          if (event.source === document.querySelector('iframe')?.contentWindow && event.data?.type === 'palladium-size') {
            window.webkit.messageHandlers.notebookHTMLHeight.postMessage(event.data.height);
          }
        });
        """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView.navigationDelegate = coordinator
        webView.setValue(false, forKey: "drawsBackground")
        addSubview(webView)
        isHidden = true
        setAccessibilityIdentifier("document.embeddedHTML")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(source: String, dark: Bool, accent: NSColor) {
        let theme = NotebookHTMLSurface.theme(dark: dark, accent: Color(nsColor: accent), bottomInset: 0)
        coordinator.theme = theme
        if loadedSource != source {
            loadedSource = source
            hasMeasuredContent = false; isHidden = true
            webView.loadHTMLString(NotebookCustomUI.document(source: source, theme: theme, embedded: true), baseURL: nil)
        } else { coordinator.updateTheme(webView) }
    }
    override func layout() {
        super.layout()
        webView.frame = bounds
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let number = message.body as? NSNumber else { return }
        let value = number.doubleValue
        guard value.isFinite, value >= 0 else { return }
        let height = min(10_000, max(24, ceil(value) + 2))
        guard !hasMeasuredContent || abs(height - contentHeight) > 1 else { return }
        contentHeight = height
        hasMeasuredContent = true
        heightChanged?()
        // Apply the measured height to TextKit before exposing the web content.
        // In particular, the first report must run even when the height is unchanged.
        isHidden = false
    }
    func stop() {
        heightChanged = nil; webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "notebookHTMLHeight")
    }
    private final class WeakHeightHandler: NSObject, WKScriptMessageHandler {
        weak var owner: MarkdownHTMLView?
        init(_ owner: MarkdownHTMLView) { self.owner = owner }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            owner?.userContentController(userContentController, didReceive: message)
        }
    }
}
