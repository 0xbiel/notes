import XCTest
import AppKit
@testable import Notes

final class DocumentReadingWidthTests: XCTestCase {
    @MainActor func testStandardCapsAndCentersTextWhileNarrowWindowsAndWideKeepExistingMargins() throws {
        _ = NSApplication.shared
        let view = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 1200, height: 700))
        let source = "# Reading\n\n" + String(repeating: "Invented text for wrapping. ", count: 80) + "\n\n| First | Second |\n| --- | --- |\n| A | B |"
        view.string = source; view.liveEditing = false; view.renderMarkdown()
        view.readingWidth = .standard
        XCTAssertEqual(view.textContainerInset.width, 260)
        XCTAssertEqual(view.textContainer?.size.width, 680)
        XCTAssertEqual(view.renderedTables.first?.layout.width, 680)
        XCTAssertEqual(view.string, source)
        view.frame.size.width = 500
        XCTAssertEqual(view.textContainerInset.width, 22)
        XCTAssertEqual(view.textContainer?.size.width, 456)
        view.frame.size.width = 1200; view.readingWidth = .wide
        XCTAssertEqual(view.textContainerInset.width, 40)
        XCTAssertEqual(view.textContainer?.size.width, 1120)
        XCTAssertEqual(view.string, source)
        XCTAssertNil(DocumentReadingWidth(rawValue: "invalid"))
    }
}
