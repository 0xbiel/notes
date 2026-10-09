import XCTest
import AppKit
@testable import Notes

final class NotebookCaretTests: XCTestCase {
    @MainActor func testFocusedEditorAndNewEditingUseAccentOnlyWithinOwnWindow() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let otherWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let other = NSTextView(frame: editor.frame)
        window.contentView?.addSubview(editor); otherWindow.contentView?.addSubview(other)
        let bridge = NotebookAccentCaretObserver(frame: .zero); window.contentView?.addSubview(bridge)
        XCTAssertTrue(window.makeFirstResponder(editor))
        bridge.caretColor = .systemPurple; bridge.updateCurrentEditor()
        XCTAssertEqual(editor.insertionPointColor, .systemPurple)
        bridge.caretColor = .systemOrange
        NotificationCenter.default.post(name: NSText.didBeginEditingNotification, object: editor)
        XCTAssertEqual(editor.insertionPointColor, .systemOrange)
        other.insertionPointColor = .systemGreen
        NotificationCenter.default.post(name: NSText.didBeginEditingNotification, object: other)
        XCTAssertEqual(other.insertionPointColor, .systemGreen)
    }
}
