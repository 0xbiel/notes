import XCTest
import LectureCore

final class MarkdownHTMLTests: XCTestCase {
    func testRawAccountingSectionsShareStylesWithoutSwallowingMarkdown() {
        let source = """
        # Reclassification 🧾

        <style>
        .asiento-ui { color: var(--notebook-text); }
        </style>

        Before the journal.

        <section class="asiento-ui" aria-label="An amount > zero">
        <div><div>Debe: 42.857,14</div></div>
        <details><summary>Ver comprobación</summary><p>Balance: 0,00</p></details>
        <script>const example = "</section>";</script>
        </section>

        ## Following explanation

        This paragraph is still Markdown.
        """
        let document = MarkdownHTML.parse(source)
        XCTAssertEqual(document.blocks.count, 1); XCTAssertEqual(document.supportRanges.count, 1)
        XCTAssertTrue(document.styles.contains(".asiento-ui"))
        XCTAssertTrue(document.blocks[0].source.contains("Debe: 42.857,14"))
        XCTAssertFalse(document.blocks[0].source.contains("Following explanation"))
        XCTAssertEqual((source as NSString).substring(with: document.blocks[0].range), document.blocks[0].source)
    }
    func testCodeExamplesCommentsAndIncompleteHTMLRemainSource() {
        let source = """
        ```html
        <section>Code example</section>
        ```
        ~~~~html
        <div>Another example</div>
        ~~~~
        <!--
        <section>Comment</section>
        -->
            <div>Indented code</div>

        <section>Incomplete HTML

        ## Ordinary heading
        """
        XCTAssertTrue(MarkdownHTML.parse(source).blocks.isEmpty)
    }
    func testExplicitUIFencesAndMultipleRawBlocksKeepStableIdentity() {
        let source = """
        ```html-ui
        <section><button>Check</button></section>
        ```

        Explanation between widgets.

        <div><div>Second widget</div></div>

        <script>window.example = 1;</script>
        """
        let parsed = MarkdownHTML.parse(source)
        XCTAssertEqual(parsed.blocks.count, 2)
        XCTAssertEqual(parsed.supportRanges.count, 1)
        XCTAssertTrue(parsed.scripts.contains("window.example"))
        XCTAssertFalse(parsed.blocks[0].source.contains("```"))
        XCTAssertFalse(parsed.blocks[1].source.contains("Explanation"))
        XCTAssertEqual(parsed.blocks.map(\.id), MarkdownHTML.parse("# Added heading\n\n" + source).blocks.map(\.id))
    }
}
