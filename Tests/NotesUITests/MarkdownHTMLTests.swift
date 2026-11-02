import XCTest
import AppKit
import WebKit
@testable import Notes

final class MarkdownHTMLViewTests: XCTestCase {
    @MainActor private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<160 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Embedded Markdown HTML did not finish laying out")
    }
    @MainActor func testHTMLInMarkdownRendersResizesAndPreservesEditableSource() async throws {
        _ = NSApplication.shared
        let source = """
        # Reclassification at N+3

        One year remains until payment.

        <style>
        .asiento-ui { border:1px solid var(--notebook-border); padding:16px; border-radius:var(--notebook-radius); }
        .as-titulo { font-weight:600; } details div { height:220px; }
        </style>

        <section class="asiento-ui" aria-label="Accounting entry">
        <p class="as-titulo">Reclasificación al cierre de N+3</p>
        <table><tr><td>Debe</td><td>Haber</td></tr><tr><td>(143) 42.857,14 €</td><td>(5293) 42.857,14 €</td></tr></table>
        <details><summary>Asiento cuadrado · Ver comprobación</summary><div>Debe = Haber; diferencia 0,00 €.</div></details>
        <script>window.addEventListener('message', e => { if(e.data === 'expand') document.querySelector('details').open=true; });</script>
        </section>

        ## After the entry

        **No expense is generated** and the total debt is unchanged.
        """
        let view = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 820, height: 700))
        let scroll = MarkdownScrollView(frame: view.frame)
        scroll.documentView = view
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = scroll
        defer { window.close() }
        view.string = source; view.liveEditing = false; view.isEditable = false
        view.renderMarkdown(); view.layoutManager?.ensureLayout(for: view.textContainer!); view.sizeToFit()
        XCTAssertEqual(view.renderedHTML.count, 1)
        XCTAssertTrue(view.renderedTables.isEmpty, "Tables inside HTML belong to the web frame")
        let embedded = try XCTUnwrap(view.renderedHTML.first?.view)
        try await waitFor { !embedded.webView.isLoading && embedded.contentHeight != 160 }
        XCTAssertEqual(view.string, source)
        XCTAssertGreaterThan(embedded.frame.width, 500)
        XCTAssertGreaterThan(embedded.frame.minY, 50)
        func followingHeadingY() -> CGFloat {
            let location = (source as NSString).range(of: "## After the entry").location
            let manager = view.layoutManager!
            manager.ensureLayout(for: view.textContainer!)
            let glyph = manager.glyphIndexForCharacter(at: location)
            return manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + view.textContainerOrigin.y
        }
        XCTAssertGreaterThanOrEqual(followingHeadingY(), embedded.frame.maxY)
        let originalHeight = embedded.contentHeight
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            embedded.webView.evaluateJavaScript("document.querySelector('iframe').contentWindow.postMessage('expand', '*')") { _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        try await waitFor { embedded.contentHeight > originalHeight + 150 }
        XCTAssertGreaterThanOrEqual(followingHeadingY(), embedded.frame.maxY)
        view.appearance = NSAppearance(named: .darkAqua); view.renderMarkdown()
        XCTAssertTrue(view.renderedHTML.first?.view === embedded)
        view.setFrameSize(NSSize(width: 600, height: view.frame.height))
        XCTAssertTrue(view.renderedHTML.first?.view === embedded)
        XCTAssertLessThan(embedded.frame.width, 600)
        view.liveEditing = true; view.isEditable = true; view.renderMarkdown()
        XCTAssertTrue(view.renderedHTML.isEmpty); XCTAssertNil(embedded.superview)
        XCTAssertEqual(view.string, source)
        XCTAssertFalse(view.undoManager?.canUndo ?? true, "Rendering never changes the source or undo history")
    }
    @MainActor func testOrdinaryHTMLCodeFenceDoesNotExecuteAndNativeTableStillRenders() {
        let source = "```html\n<section>Code only</section>\n```\n\n| Native | Table |\n| --- | --- |\n| A | B |\n"
        let view = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 600))
        view.string = source; view.liveEditing = false; view.renderMarkdown()
        XCTAssertTrue(view.renderedHTML.isEmpty)
        XCTAssertEqual(view.renderedTables.count, 1)
        XCTAssertEqual(view.string, source)
    }
}
