import XCTest
@testable import LectureCore

final class MarkdownCommentsTests: XCTestCase {
    func testInlineMultilineAndUnclosedComments() {
        XCTAssertEqual(MarkdownComments.removing(from: "Hello <!-- secret -->world"), "Hello world")
        XCTAssertEqual(MarkdownComments.removing(from: "Before\n<!-- hidden\n```\n# heading\n-->\nAfter"), "Before\n\nAfter")
        XCTAssertEqual(MarkdownComments.removing(from: "Visible <!-- unfinished"), "Visible ")
        XCTAssertEqual(MarkdownComments.removing(from: "😀 <!-- hidden -->é"), "😀 é")
    }
    func testCodeAndEscapedSyntaxStayLiteral() {
        for source in ["`<!-- literal -->`", "`` <!-- literal ` --> ``", "```html\n<!-- literal -->\n```", "~~~html\n<!-- literal -->\n~~~", #"\<!-- literal -->"#] {
            XCTAssertEqual(MarkdownComments.removing(from: source), source)
        }
        XCTAssertEqual(MarkdownComments.removing(from: "`unmatched <!-- hidden -->"), "`unmatched ")
    }
    func testBlockRendererOmitsCommentContents() {
        let blocks = NotebookMarkdown.blocks("# Title\n\n<!-- hidden\nmore -->\nVisible")
        XCTAssertEqual(blocks.map(\.text), ["Title", "Visible"])
    }
}
