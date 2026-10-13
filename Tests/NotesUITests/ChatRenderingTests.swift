import XCTest
import AppKit
import SwiftUI
import LectureCore
@testable import Notes

final class ChatRenderingTests: XCTestCase {
    @MainActor func testComposerShiftReturnInsertsNewlineWithoutSubmitting() throws {
        _ = NSApplication.shared
        final class KeyWindow: NSWindow {
            override var isKeyWindow: Bool { true }
        }
        let window = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        editor.allowsUndo = true
        let target = NotebookAttachmentPasteTarget.PasteTarget(frame: editor.bounds)
        window.contentView?.addSubview(editor)
        window.contentView?.addSubview(target)
        XCTAssertTrue(window.makeFirstResponder(editor))
        editor.string = "First second"
        editor.setSelectedRange(NSRange(location: 5, length: 1))
        func event(_ modifiers: NSEvent.ModifierFlags, keyCode: UInt16 = 36) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: keyCode))
        }
        XCTAssertTrue(target.handle(try event(.shift)))
        XCTAssertEqual(editor.string, "First\nsecond")
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 6, length: 0))
        editor.undoManager?.undo()
        XCTAssertEqual(editor.string, "First second")
        XCTAssertFalse(target.handle(try event([])))
        XCTAssertFalse(target.handle(try event([.command, .shift])))
        XCTAssertEqual(editor.string, "First second")
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        XCTAssertTrue(target.handle(try event(.shift, keyCode: 76)))
        XCTAssertEqual(editor.string, "First second\n")
        target.frame.origin.y = 300
        XCTAssertFalse(target.handle(try event(.shift)))
    }

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

    func testProviderErrorsTranslateBothWaysAndPreserveHTTPStatus() {
        let rejection = "Antigravity intentó usar herramientas; respuesta rechazada."
        let english = "Antigravity tried to use tools; response rejected."
        XCTAssertEqual(NotebookAssistantText.display(rejection, language: "en"), english)
        XCTAssertEqual(NotebookAssistantText.display(english, language: "es"), rejection)
        let spanish = "OpenRouter devolvió un error (HTTP 429). No se relajaron privacidad/precio ni se cambió de proveedor. El lote se conserva para revisar o reintentar."
        let translated = NotebookAssistantText.display(spanish, language: "en")
        XCTAssertEqual(translated, "OpenRouter returned an error (HTTP 429). Privacy and cost restrictions were preserved, and the provider was not changed. The batch is saved for review or retry.")
        XCTAssertEqual(NotebookAssistantText.display(translated, language: "es"), spanish)
        let attachment = "Attachments must be 20 MB or smaller."
        let localized = NotebookAssistantText.display(attachment, language: "es")
        XCTAssertEqual(localized, "Los archivos adjuntos no pueden superar 20 MB.")
        XCTAssertEqual(NotebookAssistantText.display(localized, language: "en"), attachment)
        XCTAssertEqual(NotebookAssistantText.display("Codex devolvió un evento no permitido (tool_call); respuesta rechazada.", language: "en"),
                       "Codex returned a disallowed event (tool_call); response rejected.")
    }

    func testSavedMessagesAndStatusesRelocalizeWithoutChangingConversationText() throws {
        let error = NotebookMessage(role: "error", text: "Antigravity intentó usar herramientas; respuesta rechazada.")
        let saved = try JSONDecoder().decode(NotebookMessage.self, from: JSONEncoder().encode(error))
        XCTAssertEqual(NotebookAssistantText.message(saved, language: "en"), "Antigravity tried to use tools; response rejected.")
        XCTAssertEqual(NotebookAssistantText.message(saved, language: "es"), error.text)
        let text = "Antigravity intentó usar herramientas; respuesta rechazada."
        XCTAssertEqual(NotebookAssistantText.message(.init(role: "user", text: text), language: "en"), text)
        XCTAssertEqual(NotebookAssistantText.message(.init(role: "assistant", text: text), language: "en"), text)
        XCTAssertEqual(NotebookAssistantText.message(.init(role: "assistant", text: "Sin cambios.", appGenerated: false), language: "en"), "Sin cambios.")
        let status = NotebookMessage(role: "assistant", text: "Cambios guardados · 2 archivo(s).", appGenerated: true)
        XCTAssertEqual(NotebookAssistantText.message(status, language: "en"), "Changes saved · 2 file(s).")
        XCTAssertEqual(NotebookAssistantText.message(.init(role: "assistant", text: "Sin cambios."), language: "en"), "No changes.")
        let activity = "Validando y guardando 3 archivo(s)…"
        let translated = NotebookAssistantText.display(activity, language: "en")
        XCTAssertEqual(translated, "Validating and saving 3 file(s)…")
        XCTAssertEqual(NotebookAssistantText.display(translated, language: "es"), activity)
        XCTAssertEqual(NotebookAssistantText.display("Reading · Cuadernos/English.md", language: "es"), "Leyendo · Cuadernos/English.md")
    }

}
