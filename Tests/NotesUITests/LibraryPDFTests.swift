import XCTest
import AppKit
import PDFKit
@testable import Notes

final class LibraryPDFTests: XCTestCase {
    @MainActor func testZoomFitsPageNavigationAndTwoPageLayout() throws {
        _ = NSApplication.shared
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Palladium-PDF-" + UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = PDFDocument()
        for _ in 0..<3 {
            let image = NSImage(size: CGSize(width: 300, height: 400), flipped: false) { rect in NSColor.white.setFill(); rect.fill(); return true }
            document.insert(try XCTUnwrap(PDFPage(image: image)), at: document.pageCount)
        }
        XCTAssertTrue(document.write(to: url))
        let controller = LibraryPDFController(url: url)
        let view = LibraryPDFNativeView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.controller = controller; controller.attach(view); view.layoutSubtreeIfNeeded()
        XCTAssertEqual(controller.pageCount, 3)
        let page = try XCTUnwrap(view.document?.page(at: 0)), size = page.bounds(for: view.displayBox).size
        controller.setFit(.width)
        XCTAssertEqual(view.scaleFactor, (800 - 24) / size.width, accuracy: 0.001)
        controller.setFit(.height)
        XCTAssertEqual(view.scaleFactor, (600 - 24) / size.height, accuracy: 0.001)
        controller.zoomText = "137,5%"; controller.commitZoom()
        XCTAssertEqual(view.scaleFactor, 1.375, accuracy: 0.001); XCTAssertEqual(controller.fit, .custom)
        controller.zoomText = "not a percentage"; controller.commitZoom()
        XCTAssertEqual(view.scaleFactor, 1.375, accuracy: 0.001)
        controller.setPercentage(10000); XCTAssertEqual(view.scaleFactor, view.maxScaleFactor)
        controller.setPercentage(125)
        view.frame.size = CGSize(width: 700, height: 500); view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.scaleFactor, 1.25, accuracy: 0.001)
        controller.setTwoPages(true); controller.setFit(.width)
        XCTAssertEqual(view.displayMode, .twoUpContinuous)
        XCTAssertEqual(view.scaleFactor, (700 - 24) / (size.width * 2 + 12), accuracy: 0.001)
        controller.pageText = "3"; controller.commitPage()
        XCTAssertEqual(controller.page, 3); XCTAssertEqual(view.currentPage, view.document?.page(at: 2))
        controller.go(to: 999); XCTAssertEqual(controller.page, 3)
        controller.go(to: 0); XCTAssertEqual(controller.page, 1)
        controller.setFit(.height)
        view.frame.size = CGSize(width: 900, height: 700); view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.scaleFactor, (700 - 24) / size.height, accuracy: 0.001)
        controller.setTwoPages(false); XCTAssertEqual(view.displayMode, .singlePageContinuous)
    }
    @MainActor func testInvalidPDFHasNoPages() {
        let controller = LibraryPDFController(url: URL(fileURLWithPath: "/nonexistent/palladium.pdf"))
        XCTAssertEqual(controller.pageCount, 0)
        controller.commitZoom(); controller.go(to: 1); controller.setFit(.height)
    }
}
