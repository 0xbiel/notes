import XCTest
import AppKit
import SwiftUI
@testable import Notes

final class ChatRenderingTests: XCTestCase {
    func testMarkdownBlocksKeepCodeLiteralAndRecognizeLists() {
        let blocks = NotebookChatMarkdown.blocks("# Heading\n\n**Hello**\n\n- [ ] Draft\n- [x] Done\n1. Ordered\n> Quote\n```swift\n- [ ] literal\n```")
        XCTAssertEqual(blocks.map(\.kind), ["heading", "paragraph", "task", "checked", "list:1.", "quote", "code:swift"])
        XCTAssertEqual(blocks.last?.text, "- [ ] literal")
        XCTAssertEqual(NotebookChatMarkdown.blocks("```\npartial").last?.text, "partial")
    }
    @MainActor func testDocumentTasksPreserveSourceAndToggleWithUndo() {
        _ = NSApplication.shared
        let view = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let source = "# Tasks\n\n- [ ] Draft\n- [x] Done\n\n```\n- [ ] literal\n```\n"
        view.string = source; view.isEditable = true; view.liveEditing = true
        view.setSelectedRange(NSRange(location: source.utf16.count, length: 0)); view.renderMarkdown()
        XCTAssertEqual(view.taskItems.count, 2)
        XCTAssertEqual(view.accessibilityCustomActions()?.count, 2)
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(view.taskItems.map(\.checked), [false, true])
        view.toggleTask(at: 0)
        XCTAssertTrue(view.string.contains("- [x] Draft"))
        view.undo(nil)
        XCTAssertEqual(view.string, source)
        view.isEditable = false; view.liveEditing = false; view.renderMarkdown()
        XCTAssertEqual(view.taskItems.count, 2)
        view.toggleTask(at: 0)
        XCTAssertTrue(view.string.contains("- [x] Draft"))
        XCTAssertFalse(view.isEditable)
        XCTAssertFalse(view.liveEditing)
    }
    @MainActor func testPreviewTaskCallbackPublishesExactMarkdownWithoutEnablingTyping() throws {
        let coordinator = LiveMarkdownEditor.Coordinator()
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        var changed = "", toggled = ""
        coordinator.update(LiveMarkdownEditor(documentID: "task", text: "- [ ] Task\n", editing: false,
            onChange: { changed = $0 }, onLink: { _ in }, onTaskToggle: { toggled = $0 }), scroll: scroll)
        let view = try XCTUnwrap(coordinator.editors["task"])
        view.toggleTask(at: 0)
        XCTAssertEqual(changed, "- [x] Task\n")
        XCTAssertEqual(toggled, changed)
        XCTAssertFalse(view.isEditable)
    }
    @MainActor func testAccentColorRoundTrip() {
        let stored = NotebookAccent.encode(.purple)
        let original = NSColor(Color.purple).usingColorSpace(.sRGB)!
        let decoded = NSColor(NotebookAccent.color(stored)).usingColorSpace(.sRGB)!
        XCTAssertEqual(original.redComponent, decoded.redComponent, accuracy: 0.001)
        XCTAssertEqual(original.greenComponent, decoded.greenComponent, accuracy: 0.001)
        XCTAssertEqual(original.blueComponent, decoded.blueComponent, accuracy: 0.001)
    }

    func testSavedErrorAndDynamicActivityFollowSelectedLanguage() {
        let error = "El asistente repitió una petición de contexto. Acota la petición y vuelve a enviar."
        XCTAssertTrue(NotebookAssistantText.display(error, language: "en").hasPrefix("The assistant"))
        XCTAssertEqual(NotebookAssistantText.display(error, language: "es"), error)
        XCTAssertEqual(NotebookAssistantText.display("Consultando BOE · Art. 1", language: "en"), "Looking up BOE · Art. 1")
    }

}
