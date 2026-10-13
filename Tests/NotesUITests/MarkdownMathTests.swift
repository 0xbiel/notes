import XCTest
import AppKit
import SwiftUI
import LectureCore
@testable import Notes

final class MarkdownMathTests: XCTestCase {
    @MainActor func testScreenshotFormattingVisuals() async throws {
        let source = #"""
        **a) ¿Problema según qué ocurre con la instrucción siguiente al salto (`add r5,r0,c`)?**

        La instrucción siguiente conserva su formato de código.

        ---

        $$\text{Ciclos}=15+4=\boxed{19}$$

        ---

        $$\frac{n}{600+(n-1)150}=\frac{0{,}9}{150}\;\Rightarrow\;150n=0{,}9\,(450+150n)=405+135n\;\Rightarrow\;15n=405\;\Rightarrow\;\boxed{n=27}$$

        **Resultado final**, sin modificar el Markdown original.
        """#
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("qa/math")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for dark in [false, true] {
            for chat in [false, true] {
                let content: AnyView = chat
                    ? AnyView(NotebookChatMarkdown(text: source).padding(24))
                    : AnyView(LiveMarkdownEditor(documentID: "formatting-qa", text: source, editing: false, onChange: { _ in }, onLink: { _ in }))
                let host = NSHostingView(rootView: content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(Color(nsColor: .textBackgroundColor)).environment(\.colorScheme, dark ? .dark : .light))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 560), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = host
                host.frame = NSRect(x: 0, y: 0, width: 800, height: 560)
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(200))
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let filename = "formatting-\(chat ? "chat" : "note")-\(dark ? "dark" : "light").png"
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(filename))
                window.close()
            }
        }
    }
    @MainActor func testBoxedScreenshotFormulasRenderWithoutChangingSource() throws {
        let formulas = [#"\text{Ciclos}=15+4=\boxed{19}"#,
                        #"\frac{n}{600+(n-1)150}=\frac{0{,}9}{150}\;\Rightarrow\;150n=0{,}9\,(450+150n)=405+135n\;\Rightarrow\;15n=405\;\Rightarrow\;\boxed{n=27}"#,
                        #"\boxed{\frac{1}{2}}"#, #"\boxed{x}^{2}_{i}"#, #"\boxed{\boxed{19}}"#]
        let source = formulas.map { "$$" + $0 + "$$" }.joined(separator: "\n\n")
        let spans = MarkdownMath.spans(in: source)
        XCTAssertEqual(spans.count, formulas.count)
        for span in spans { XCTAssertNotNil(MarkdownMathRenderer.render(span, source: source)) }
        XCTAssertEqual(MarkdownMathText.attributed(source).string.filter { $0 == "\u{fffc}" }.count, formulas.count)
        let view = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 1400, height: 700))
        view.string = source; view.liveEditing = false; view.renderMarkdown()
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(view.renderedMath.count, formulas.count)
        let longSpan = spans[1]
        let original = try XCTUnwrap(MarkdownMathRenderer.render(longSpan, source: source))
        for width: CGFloat in [320, 680, 1200] {
            let fitted = original.fitting(width: width)
            XCTAssertLessThanOrEqual(fitted.size.width, width)
            XCTAssertEqual(fitted.size.height / fitted.size.width, original.size.height / original.size.width, accuracy: 0.001)
            let rich = MarkdownMathText.attributed("$$" + formulas[1] + "$$", mathWidth: width)
            let attachment = try XCTUnwrap(rich.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
            XCTAssertLessThanOrEqual(attachment.bounds.width, width)
        }
        view.setFrameSize(NSSize(width: 400, height: 700))
        for render in view.renderedMath {
            XCTAssertLessThanOrEqual(try XCTUnwrap(view.mathRect(render)).maxX, view.bounds.maxX)
        }
        XCTAssertEqual(view.string, source)
    }

    func testChatThematicBreaksAreBlocksAndCodeStaysLiteral() {
        let source = "Before\n\n---\n\nAfter\n\n***\n\n_ _ _\n\n```text\n---\n```\n\n| A |\n| --- |\n| B |"
        let blocks = NotebookChatMarkdown.blocks(source)
        XCTAssertEqual(blocks.filter { $0.kind == "rule" }.count, 3)
        XCTAssertEqual(blocks.first(where: { $0.kind == "code:text" })?.text, "---")
        XCTAssertEqual(blocks.filter { $0.kind == "table" }.count, 1)
    }

    @MainActor func testBoldContainingInlineCodeAndThematicBreaksInNotes() throws {
        let heading = "**a) ¿Problema según qué ocurre con la instrucción siguiente al salto (`add r5,r0,c`)?**"
        let source = heading + "\n\n---\n\n***\n\n_ _ _\n\n```text\n**literal**\n---\n```\n\n`**literal**`"
        let view = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 1400, height: 500))
        view.string = source; view.liveEditing = false; view.renderMarkdown()
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(view.renderedRules.count, 3)
        let storage = try XCTUnwrap(view.textStorage)
        for term in ["a)", "add r5,r0,c"] {
            let position = (source as NSString).range(of: term).location
            let font = try XCTUnwrap(storage.attribute(.font, at: position, effectiveRange: nil) as? NSFont)
            XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
            if term.hasPrefix("add") { XCTAssertTrue(font.isFixedPitch) }
        }
        XCTAssertEqual(storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .clear)
        let literal = (source as NSString).range(of: "**literal**").location
        XCTAssertNotEqual(storage.attribute(.foregroundColor, at: literal, effectiveRange: nil) as? NSColor, .clear)
        let chat = NotebookChatMarkdown.inlineAttributed(heading, accent: .purple)
        XCTAssertFalse(String(chat.characters).contains("**"))
        XCTAssertTrue(chat.runs.contains { ($0.inlinePresentationIntent ?? []).contains(.stronglyEmphasized) })
        for range in view.renderedRules { XCTAssertGreaterThan(try XCTUnwrap(view.thematicRuleRect(range)).width, 600) }
        let rule = try XCTUnwrap(view.renderedRules.first)
        view.liveEditing = true
        view.setSelectedRange(NSRange(location: rule.location, length: 0))
        view.renderMarkdown()
        XCTAssertEqual(view.renderedRules.count, 2)
        XCTAssertNotEqual(storage.attribute(.foregroundColor, at: rule.location, effectiveRange: nil) as? NSColor, .clear)
        XCTAssertEqual(view.string, source)
    }
    @MainActor func testScreenshotFormulasRenderInNotesTablesAndChatWithoutSourceChanges() throws {
        let formulas = [#"T_{orig}(n)=n\cdot T"#, #"t=\max{t_1,\dots,t_k}+d"#,
                        #"TLI=k\cdot t"#, #"T_{seg}(n)=TLI+(n-1)t=kt+(n-1)t"#,
                        #"S(n)=\dfrac{n,T}{k,t+(n-1),t}"#,
                        #"S_{max}=\lim_{n\to\infty}S(n)=\dfrac{T}{t}"#,
                        #"W_k(n)=\dfrac{n}{k,t+(n-1),t}"#, #"W_{max}=\dfrac{1}{t}"#]
        let source = formulas.map { "$" + $0 + "$" }.joined(separator: "\n\n")
        let spans = MarkdownMath.spans(in: source)
        XCTAssertEqual(spans.count, formulas.count)
        for span in spans { XCTAssertNotNil(MarkdownMathRenderer.render(span, source: source)) }
        let chat = MarkdownMathText.attributed(source)
        XCTAssertEqual(chat.string.filter { $0 == "\u{fffc}" }.count, formulas.count)
        let view = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 700))
        view.string = source; view.liveEditing = false; view.renderMarkdown()
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(view.renderedMath.count, formulas.count)
        let markdown = "| Formula |\n| --- |\n" + formulas.map { "| $" + $0 + "$ |" }.joined(separator: "\n")
        let table = try XCTUnwrap(MarkdownTables.blocks(in: markdown).first?.table)
        let layout = MarkdownTableLayout(table: table, width: 680)
        XCTAssertEqual(layout.texts.reduce(0) { $0 + $1.string.filter { $0 == "\u{fffc}" }.count }, formulas.count)
        XCTAssertEqual(MarkdownMathRenderer.renderingSource(#"\dfrac{\dfrac{1}{2}}{\dots}"#), #"{\displaystyle\frac{{\displaystyle\frac{1}{2}}}{\ldots}}"#)
        XCTAssertEqual(MarkdownMathRenderer.renderingSource(#"\dfracUnknown{1}{2} \unknown \{dots\}"#), #"\dfracUnknown{1}{2} \unknown \{dots\}"#)
        let fraction = #"$\tfrac12$"#
        XCTAssertNotNil(MarkdownMathRenderer.render(try XCTUnwrap(MarkdownMath.spans(in: fraction).first), source: fraction))
    }
    static let example = #"""
    ### 1.1 Fundamental Definitions
    - **Alphabet ($\Sigma$):** A finite, non-empty set of symbols (e.g., $\Sigma = \{a, b\}$ or $\Gamma = \{0, 1\}$).
    - **Word / String ($x$):** A finite sequence of symbols chosen from an alphabet $\Sigma$.
    - **Empty Word ($\lambda$):** The unique string containing 0 symbols. Note that $\lambda \neq \emptyset$ and $\{\lambda\} \neq \emptyset$.
    - **Length ($|x|$):** The total number of symbols in word $x$:
      - $|\lambda| = 0$
      - $|ya| = |y| + 1$ for $a \in \Sigma, y \in \Sigma^*$
      - $|xy| = |x| + |y|$
    - **Symbol Count ($|x|_a$):** The number of occurrences of symbol $a$ in string $x$.

    ### 1.2 Powers of the Alphabet and Languages
    - **$\Sigma^n$:** The set of all words of length $n$ over $\Sigma$, with $\Sigma^0 = \{\lambda\}$.
    - **Universal Language / Kleene Star ($\Sigma^*$):** The set of all possible finite words over $\Sigma$:
      $$\Sigma^* = \bigcup_{i \ge 0} \Sigma^i$$
    - **Positive Closure ($\Sigma^+$):** All non-empty words over $\Sigma$:
      $$\Sigma^+ = \Sigma^* \setminus \{\lambda\} = \bigcup_{i \ge 1} \Sigma^i$$
    - **Language ($L$):** Any subset $L \subseteq \Sigma^*$.
      - $\emptyset$: Empty language (contains no words).
      - $\{\lambda\}$: Language containing only the empty word.
      - A language over a finite alphabet is either finite or countably infinite (same cardinality as $\mathbb{N}$).
    """#

    func testMathDelimitersIgnoreCodeCurrencyEscapesAndUnclosedExpressions() {
        let text = #"""
        `$x$` and ``$y$`` cost $5 and $10. Escaped \$z\$.
        ```latex
        $$\Sigma$$
        ```
        $a_i$ and \(b^2\) then:
        \[
        \frac{1}{2}
        \]
        $$c+d$$
        Unclosed $x and $$y
        """#
        let spans = MarkdownMath.spans(in: text)
        XCTAssertEqual(spans.count, 4)
        XCTAssertEqual(spans.filter(\.display).count, 2)
        XCTAssertEqual((text as NSString).substring(with: spans[0].content), "a_i")
    }
    @MainActor func testAllUserFormulasRenderAndSourceReappearsAtCaret() throws {
        let spans = MarkdownMath.spans(in: Self.example)
        XCTAssertGreaterThan(spans.count, 25)
        XCTAssertEqual(spans.filter(\.display).count, 2)
        for span in spans { XCTAssertNotNil(MarkdownMathRenderer.render(span, source: Self.example), (Self.example as NSString).substring(with: span.content)) }
        let view = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 900, height: 1200))
        view.string = Self.example; view.liveEditing = false; view.renderMarkdown()
        XCTAssertEqual(view.renderedMath.count, spans.count)
        XCTAssertEqual(view.string, Self.example)
        let source = Self.example as NSString
        for render in view.renderedMath where render.span.display {
            let rect = try XCTUnwrap(view.mathRect(render))
            var next = NSMaxRange(render.span.range)
            while next < source.length, CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(source.character(at: next))!) { next += 1 }
            let glyph = view.layoutManager!.glyphIndexForCharacter(at: next)
            let nextLine = view.layoutManager!.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            XCTAssertLessThanOrEqual(rect.maxY, nextLine.minY + view.textContainerOrigin.y, "Equation must not overlap the next paragraph")
        }
        view.liveEditing = true; view.setSelectedRange(NSRange(location: spans[0].content.location, length: 0)); view.renderMarkdown()
        XCTAssertEqual(view.renderedMath.count, spans.count - 1)
        XCTAssertEqual(view.string, Self.example)
        let invalid = #"$\unknown{abc}$"#
        XCTAssertNil(MarkdownMathRenderer.render(try XCTUnwrap(MarkdownMath.spans(in: invalid).first), source: invalid))
    }
    @MainActor func testTransitionTableMathRendersWithoutChangingMarkdown() throws {
        let source = #"""
        | Estado | $a$ | $b$ |
        | :--- | :---: | ---: |
        | $\to q_0$ | $q_1$ | $q_0$ |
        | $*q_1$ | $q_1$ | $q_0$ |
        | $\frac{1}{\sum_{i=1}^{n} i}$ | **Bold** | `$q_0$` |
        """#
        let table = try XCTUnwrap(MarkdownTables.blocks(in: source).first?.table)
        let layout = MarkdownTableLayout(table: table, width: 680)
        XCTAssertEqual(layout.texts.reduce(0) { $0 + $1.string.filter { $0 == "\u{fffc}" }.count }, 9)
        XCTAssertEqual(layout.texts.last?.string, "$q_0$")
        XCTAssertFalse(layout.texts.contains { $0.string.contains("PALLADIUMMATH") })
        XCTAssertGreaterThan(layout.rowHeights.last!, 36, "Tall equations expand the row")
        let view = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
        view.string = source; view.liveEditing = false; view.renderMarkdown()
        XCTAssertEqual(view.string, source)
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("qa/math")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for dark in [false, true] {
            let canvas = MarkdownTablePreview.TableCanvas(frame: NSRect(x: 0, y: 0, width: 680, height: layout.height))
            canvas.table = table; canvas.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let bitmap = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
            canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(dark ? "table-dark.png" : "table-light.png"))
        }
    }

    @MainActor func testNativeMathRenderLightDarkAndChat() async throws {
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("qa/math")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for dark in [false, true] {
            let host = NSHostingView(rootView: LiveMarkdownEditor(documentID: "math", text: Self.example, editing: false, onChange: { _ in }, onLink: { _ in }).background(Color(nsColor: .textBackgroundColor)).environment(\.colorScheme, dark ? .dark : .light))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 1200), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host; host.frame = NSRect(x: 0, y: 0, width: 1000, height: 1200)
            host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(200)); host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(dark ? "dark.png" : "light.png"))
            window.close()
        }
        for (index, span) in MarkdownMath.spans(in: Self.example).filter(\.display).enumerated() {
            let render = try XCTUnwrap(MarkdownMathRenderer.render(span, source: Self.example, fontSize: 20))
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(render.image.tiffRepresentation)))
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("formula-\(index).png"))
        }
        let rich = MarkdownMathText.attributed(#"**Alphabet ($\Sigma$)** and $\frac{1}{2}$"#)
        XCTAssertEqual(rich.string.filter { $0 == "\u{fffc}" }.count, 2)
        XCTAssertFalse(rich.string.contains("PALLADIUMMATH"))
        let blocks = NotebookChatMarkdown.blocks(Self.example)
        XCTAssertEqual(blocks.filter { $0.kind == "math" }.count, 2)
    }
}
