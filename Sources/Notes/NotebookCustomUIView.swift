import SwiftUI
import WebKit
import LectureCore

struct NotebookCustomUIView: View {
    let workspace: SafeWorkspace
    let path: String
    var notebookColor: String? = nil
    var bottomInset: CGFloat = 0
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("notes.accent") private var accent = ""
    @AppStorage("notes.language") private var language = "es"
    var body: some View {
        if let data = try? workspace.readFile(path), let source = String(data: data, encoding: .utf8),
           (try? NotebookCustomUI.validate(source)) != nil {
            NotebookHTMLSurface(source: source, theme: NotebookHTMLSurface.theme(dark: colorScheme == .dark,
                accent: notebookColor.flatMap(NotebookColor.init(rawValue:))?.color ?? NotebookAccent.color(accent), bottomInset: bottomInset))
                .accessibilityIdentifier("notebook.customUI")
        } else {
            ContentUnavailableView(language == "en" ? "View unavailable" : "Vista no disponible", systemImage: "rectangle.and.text.magnifyingglass")
        }
    }
}

struct NotebookHTMLSurface: NSViewRepresentable {
    let source: String
    let theme: [String: String]
    static func theme(dark: Bool, accent: Color, bottomInset: CGFloat) -> [String: String] {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        var result: [String: String] = [:]
        appearance.performAsCurrentDrawingAppearance {
            func css(_ color: NSColor) -> String {
                let rgb = color.usingColorSpace(.sRGB) ?? .black
                return String(format: "rgba(%.0f,%.0f,%.0f,%.3f)", rgb.redComponent * 255, rgb.greenComponent * 255, rgb.blueComponent * 255, rgb.alphaComponent)
            }
            let tint = NSColor(accent).usingColorSpace(.sRGB) ?? .controlAccentColor
            let luminance = 0.2126 * tint.redComponent + 0.7152 * tint.greenComponent + 0.0722 * tint.blueComponent
            result = ["mode": dark ? "dark" : "light", "--notebook-background": css(.textBackgroundColor),
                "--notebook-surface": css(.controlBackgroundColor), "--notebook-text": css(.labelColor),
                "--notebook-secondary": css(.secondaryLabelColor), "--notebook-border": css(.separatorColor),
                "--notebook-accent": css(tint), "--notebook-on-accent": css(luminance > 0.6 ? .black : .white),
                "--notebook-bottom-inset": "\(max(0, bottomInset))px"]
        }
        return result
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        updateNSView(view, context: context)
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.theme = theme
        if coordinator.source != source {
            coordinator.source = source
            view.loadHTMLString(NotebookCustomUI.document(source: source, theme: theme), baseURL: nil)
        } else { coordinator.updateTheme(view) }
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading(); view.navigationDelegate = nil
    }
    final class Coordinator: NSObject, WKNavigationDelegate {
        var source: String?
        var theme: [String: String] = [:]
        var appliedTheme: [String: String] = [:]
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            appliedTheme = [:]; updateTheme(webView)
        }
        func updateTheme(_ view: WKWebView) {
            guard appliedTheme != theme, !view.isLoading,
                  let data = try? JSONSerialization.data(withJSONObject: ["type": "palladium-theme", "theme": theme]),
                  let json = String(data: data, encoding: .utf8) else { return }
            appliedTheme = theme
            view.evaluateJavaScript("document.querySelector('iframe')?.contentWindow.postMessage(\(json), '*')", completionHandler: nil)
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            let url = navigationAction.request.url
            // loadHTMLString and srcdoc are the only permitted documents.
            let document = url?.absoluteString.components(separatedBy: "#").first ?? ""
            let local = document == "about:blank" || document == "about:srcdoc"
            decisionHandler(local && navigationAction.navigationType != .linkActivated ? .allow : .cancel)
        }
    }
}
