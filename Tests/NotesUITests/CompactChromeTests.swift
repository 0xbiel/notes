import XCTest
import AppKit
@testable import Notes

final class CompactChromeTests: XCTestCase {
    @MainActor func testCrossingGraceAndReentryCancelsHide() {
        let chrome = CompactChrome()
        chrome.toggleCompact()
        chrome.update(now: -1, sidebarHit: false, toolbarHit: false, hold: false)
        chrome.update(now: 0, sidebarHit: true, toolbarHit: false, hold: false)
        chrome.update(now: 1, sidebarHit: false, toolbarHit: false, hold: false)
        chrome.update(now: 1.1, sidebarHit: false, toolbarHit: false, hold: false)
        XCTAssertTrue(chrome.sidebarVisible)
        chrome.update(now: 1.12, sidebarHit: true, toolbarHit: false, hold: false)
        chrome.update(now: 1.2, sidebarHit: false, toolbarHit: false, hold: false)
        XCTAssertTrue(chrome.sidebarVisible)
        chrome.update(now: 1.36, sidebarHit: false, toolbarHit: false, hold: false)
        XCTAssertFalse(chrome.sidebarVisible)
    }
    @MainActor func testOnlyExplicitPinSurvivesPointerExit() {
        let chrome = CompactChrome()
        chrome.toggleCompact()
        chrome.toggleSidebar()
        chrome.update(now: 1, sidebarHit: false, toolbarHit: false, hold: false)
        chrome.update(now: 100, sidebarHit: false, toolbarHit: false, hold: false)
        XCTAssertFalse(chrome.sidebarVisible)
        chrome.togglePin()
        chrome.update(now: 200, sidebarHit: false, toolbarHit: false, hold: false)
        XCTAssertTrue(chrome.sidebarVisible)
        chrome.toggleSidebar()
        XCTAssertFalse(chrome.sidebarVisible)
        XCTAssertFalse(chrome.pinned)
    }
    @MainActor func testMenuFieldOrDragHoldResetsExitGrace() {
        let chrome = CompactChrome()
        chrome.toggleCompact()
        chrome.update(now: -1, sidebarHit: false, toolbarHit: false, hold: false)
        chrome.update(now: 0, sidebarHit: true, toolbarHit: true, hold: false)
        chrome.update(now: 1, sidebarHit: false, toolbarHit: false, hold: false)
        chrome.update(now: 2, sidebarHit: false, toolbarHit: false, hold: true)
        XCTAssertTrue(chrome.sidebarVisible)
        XCTAssertTrue(chrome.toolbarVisible)
        chrome.update(now: 10, sidebarHit: false, toolbarHit: false, hold: false)
        chrome.update(now: 10.2, sidebarHit: false, toolbarHit: false, hold: false)
        XCTAssertFalse(chrome.sidebarVisible)
        XCTAssertTrue(chrome.toolbarVisible)
        chrome.update(now: 11.1, sidebarHit: false, toolbarHit: false, hold: false)
        XCTAssertFalse(chrome.toolbarVisible)
    }
    @MainActor func testWindowButtonsLiveInsideSidebarAndRestore() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 620), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let button = window.standardWindowButton(.closeButton)!
        let originalParent = button.superview
        let host = WindowButtonsView(frame: NSRect(x: 18, y: 550, width: 76, height: 44))
        window.contentView?.addSubview(host)
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(button.superview === host)
        XCTAssertTrue(host.bounds.contains(button.frame))
        XCTAssertTrue(CompactChrome().sidebarVisible)
        originalParent?.addSubview(button)
        button.setFrameOrigin(NSPoint(x: 0, y: 0))
        host.installButtons()
        XCTAssertTrue(button.superview === host)
        XCTAssertEqual(button.frame.midY, host.bounds.midY)
        host.restoreButtons()
        XCTAssertTrue(button.superview === originalParent)
        window.close()
    }
    @MainActor func testEnteringCompactClearsPinAndCloseStaysClosedUntilPointerExit() {
        let chrome = CompactChrome()
        chrome.togglePin()
        chrome.toggleCompact()
        chrome.update(now: 0, sidebarHit: true, toolbarHit: false, hold: false)
        XCTAssertFalse(chrome.sidebarVisible)
        XCTAssertFalse(chrome.pinned)
        chrome.update(now: 1, sidebarHit: false, toolbarHit: false, hold: false)
        chrome.update(now: 2, sidebarHit: true, toolbarHit: false, hold: false)
        XCTAssertTrue(chrome.sidebarVisible)
        chrome.toggleSidebar()
        chrome.update(now: 3, sidebarHit: true, toolbarHit: false, hold: false)
        XCTAssertFalse(chrome.sidebarVisible)
    }
    @MainActor func testNativeButtonsHideAndRestoreWithoutReplacingEditor() {
        _ = NSApplication.shared
        let chrome = CompactChrome()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 620), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let editor = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        editor.string = "Acción, niño y cafe\u{301}"
        let selected = NSRange(location: 8, length: 4)
        editor.setSelectedRange(selected)
        window.contentView?.addSubview(editor)
        window.makeFirstResponder(editor)
        let bridge = ChromeWindowView(chrome: chrome)
        window.contentView?.addSubview(bridge)
        chrome.toggleCompact(); bridge.syncButtons()
        for type in ChromeWindowView.buttonTypes { XCTAssertEqual(window.standardWindowButton(type)?.isHidden, true) }
        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertEqual(editor.selectedRange(), selected)
        chrome.toggleSidebar(); bridge.syncButtons()
        for type in ChromeWindowView.buttonTypes { XCTAssertEqual(window.standardWindowButton(type)?.isHidden, false) }
        bridge.detach()
        XCTAssertFalse(window.styleMask.contains(.fullSizeContentView))
        XCTAssertEqual(window.titleVisibility, .visible)
        XCTAssertEqual(editor.string, "Acción, niño y cafe\u{301}")
        window.close()
    }
}
