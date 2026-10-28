import XCTest
import AppKit
import PDFKit
import SwiftUI
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
    @MainActor func testArrowKeysTurnFocusedPDFPagesAndLeaveTextEditingAlone() throws {
        _ = NSApplication.shared
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = PDFDocument()
        for _ in 0..<3 {
            let image = NSImage(size: CGSize(width: 300, height: 400), flipped: false) { rect in NSColor.white.setFill(); rect.fill(); return true }
            document.insert(try XCTUnwrap(PDFPage(image: image)), at: document.pageCount)
        }
        XCTAssertTrue(document.write(to: url))
        if let output = ProcessInfo.processInfo.environment["NOTES_PDF_TOOLBAR_SCREENSHOT"] {
            let host = NSHostingView(rootView: LibraryPDFView(url: url).frame(width: 420, height: 500))
            host.frame = NSRect(x: 0, y: 0, width: 420, height: 500)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output))
        }
        let controller = LibraryPDFController(url: url)
        let view = LibraryPDFNativeView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        view.controller = controller; controller.attach(view)
        let window = PDFKeyboardTestWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        container.addSubview(view); window.contentView = container
        defer { view.stopKeyMonitor(); window.close() }
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(window.makeFirstResponder(view))
        func key(_ code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
        }
        XCTAssertTrue(view.handleNavigationEvent(try key(124)))
        XCTAssertEqual(controller.page, 2)
        XCTAssertTrue(view.handleNavigationEvent(try key(124)))
        XCTAssertEqual(controller.page, 3)
        XCTAssertTrue(view.handleNavigationEvent(try key(124)))
        XCTAssertEqual(controller.page, 3)
        XCTAssertTrue(view.handleNavigationEvent(try key(123)))
        XCTAssertEqual(controller.page, 2)
        for modifier: NSEvent.ModifierFlags in [.shift, .command, .option, .control] {
            XCTAssertFalse(view.handleNavigationEvent(try key(123, modifiers: modifier)))
            XCTAssertEqual(controller.page, 2)
        }
        let editor = NSTextView(frame: NSRect(x: 0, y: 510, width: 600, height: 50))
        container.addSubview(editor)
        XCTAssertTrue(window.makeFirstResponder(editor))
        XCTAssertFalse(view.handleNavigationEvent(try key(124)))
        XCTAssertEqual(controller.page, 2)
        // Editable PDF annotations also retain caret movement.
        view.addSubview(editor)
        XCTAssertTrue(window.makeFirstResponder(editor))
        XCTAssertFalse(view.handleNavigationEvent(try key(124)))
        XCTAssertEqual(controller.page, 2)
        XCTAssertTrue(window.makeFirstResponder(view))
        controller.go(to: 1)
        XCTAssertTrue(view.handleNavigationEvent(try key(123)))
        XCTAssertEqual(controller.page, 1)
    }

    @MainActor func testInvalidPDFHasNoPages() {
        let controller = LibraryPDFController(url: URL(fileURLWithPath: "/nonexistent/palladium.pdf"))
        XCTAssertEqual(controller.pageCount, 0)
        controller.commitZoom(); controller.go(to: 1); controller.setFit(.height)
    }
}

@MainActor private final class PDFKeyboardTestWindow: NSWindow {
    override var isKeyWindow: Bool { true }
}
