import XCTest
import AppKit
import SwiftUI
import LectureCore
@testable import Notes

final class EditorTests: XCTestCase {
    @MainActor func testEscapedMarkdownPunctuationRendersWithoutChangingSource() throws {
        _ = NSApplication.shared
        let view = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 400))
        let sentence = #"\* Con respecto a un nivel dado de eficacia."#
        let source = sentence + "\n\n" + #"\*literal* and `\*code` and $\alpha$"# + "\n"
        view.string = source
        view.liveEditing = false
        view.renderMarkdown()
        let storage = try XCTUnwrap(view.textStorage)
        func font(at index: Int) throws -> NSFont {
            try XCTUnwrap(storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont)
        }
        XCTAssertLessThan(try font(at: 0).pointSize, 1)
        XCTAssertGreaterThan(try font(at: 1).pointSize, 1)
        let literal = (source as NSString).range(of: "literal")
        XCTAssertFalse(NSFontManager.shared.traits(of: try font(at: literal.location)).contains(.italicFontMask))
        let code = (source as NSString).range(of: #"\*code"#)
        XCTAssertGreaterThan(try font(at: code.location).pointSize, 1)
        XCTAssertEqual(view.renderedMath.count, 1)
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(String(NotebookChatMarkdown.inlineAttributed(sentence, accent: .purple).characters), "* Con respecto a un nivel dado de eficacia.")

        view.liveEditing = true
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.renderMarkdown()
        XCTAssertGreaterThan(try font(at: 0).pointSize, 1)
        XCTAssertEqual(view.string, source)
    }
    @MainActor func testStartupUsesOnlyExplicitInventedWorkspaceAndDoesNotStartServices() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".test-workspaces/Startup-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("copied-course"), withIntermediateDirectories: true)
        let text = "# Inicio\n\nContenido inventado para comprobar el inicio.\n"
        try text.write(to: root.appendingPathComponent("copied-course/Inicio.md"), atomically: true, encoding: .utf8)
        try JSONSerialization.data(withJSONObject: ["originalRoot": root.appendingPathComponent("protected-original").path]).write(to: root.appendingPathComponent("original-hashes.json"))
        let model = Workbench(workspaceRoot: root)
        defer { model.ai?.stop(); model.media?.shutdown(); try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(model.errorText)
        XCTAssertEqual(model.selectedNote, "Inicio.md")
        XCTAssertEqual(model.draftText, text)
        XCTAssertFalse(model.media?.isRecording ?? true)
        XCTAssertEqual(model.media?.jobs.count, 0)
        XCTAssertFalse(model.ai?.running ?? true)
        XCTAssertTrue(model.ai?.automaticMediaIDs.isEmpty ?? false)
        XCTAssertEqual(try model.workspace?.readNote("Inicio.md"), text)
    }
    @MainActor func testSourceSelectionAndUndo() throws {
        _ = NSApplication.shared
        let view = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let original = "# Título\n\n**Cláusula** y *acción* con niño 👩🏽‍💻.\n\n- Uno\n"
        view.string = original
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.renderMarkdown()
        XCTAssertEqual(view.string, original)
        XCTAssertGreaterThan((view.textStorage!.attribute(.font, at: 0, effectiveRange: nil) as! NSFont).pointSize, 1)
        view.setSelectedRange(NSRange(location: original.utf16.count, length: 0))
        view.renderMarkdown()
        XCTAssertLessThan((view.textStorage!.attribute(.font, at: 0, effectiveRange: nil) as! NSFont).pointSize, 1)
        let selected = view.selectedRange()
        view.renderMarkdown()
        XCTAssertEqual(view.selectedRange(), selected)
        view.insertText("más información", replacementRange: selected)
        view.breakUndoCoalescing()
        XCTAssertTrue(view.string.hasSuffix("más información"))
        view.renderMarkdown()
        view.undo(nil)
        XCTAssertEqual(view.string, original)
        view.redo(nil)
        XCTAssertTrue(view.string.hasSuffix("más información"))
    }
    @MainActor func testLiteralCodeAndCleanExternalRevision() throws {
        _ = NSApplication.shared
        let view = MarkdownTextView(frame: .zero)
        let source = "# Título\n\n`**literal**`\n\n```swift\n**literal**\n```\n"
        view.string = source
        view.liveEditing = false
        view.renderMarkdown()
        let ns = source as NSString
        let literal = ns.range(of: "**literal**")
        XCTAssertGreaterThan((view.textStorage!.attribute(.font, at: literal.location, effectiveRange: nil) as! NSFont).pointSize, 1)
        XCTAssertEqual(view.string, source)
        let coordinator = LiveMarkdownEditor.Coordinator()
        let scroll = NSScrollView()
        coordinator.update(LiveMarkdownEditor(documentID: "a", text: "before", editing: true, onChange: { _ in }, onLink: { _ in }), scroll: scroll)
        coordinator.update(LiveMarkdownEditor(documentID: "a", text: "accepted proposal", editing: true, onChange: { _ in }, onLink: { _ in }), scroll: scroll)
        XCTAssertEqual(coordinator.editors["a"]?.string, "accepted proposal")
    }
    @MainActor func testFencedTextAndCodePresentationKeepsMarkdownSource() throws {
        _ = NSApplication.shared
        let view = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 460))
        if ProcessInfo.processInfo.environment["NOTES_CODE_BLOCK_APPEARANCE"] == "light" {
            view.appearance = NSAppearance(named: .aqua)
        } else if ProcessInfo.processInfo.environment["NOTES_CODE_BLOCK_APPEARANCE"] == "dark" {
            view.appearance = NSAppearance(named: .darkAqua)
        }
        let source = "Texto con `organismo autónomo` y `código` dentro de la misma línea.\n\nTambién puede envolver `un fragmento de código largo que continúa en la siguiente línea sin convertirse en un bloque grande` entre palabras.\n\n```text\nlet plain = 42\n```\n\n```swift\nlet message = \"hello\" // note\n```\n\n```json\n{\"name\": 42}\n```\n"
        view.string = source
        view.liveEditing = false
        view.renderMarkdown()
        let ns = source as NSString
        let storage = try XCTUnwrap(view.textStorage)
        func color(_ text: String) -> NSColor? {
            let range = ns.range(of: text)
            return range.location == NSNotFound ? nil : storage.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor
        }
        XCTAssertEqual(color("let plain"), NSColor.labelColor)
        XCTAssertEqual(color("let message"), NSColor.systemBlue)
        XCTAssertEqual(color("\"hello\""), NSColor.systemRed)
        XCTAssertEqual(color("// note"), NSColor.secondaryLabelColor)
        XCTAssertEqual(color("\"name\""), NSColor.systemBlue)
        let code = ns.range(of: "let message")
        let paragraph = try XCTUnwrap(storage.attribute(.paragraphStyle, at: code.location, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(paragraph.headIndent, 15)
        XCTAssertNil(storage.attribute(.backgroundColor, at: code.location, effectiveRange: nil))
        XCTAssertEqual(view.string, source)

        view.liveEditing = true
        let fence = ns.range(of: "```swift")
        view.setSelectedRange(NSRange(location: fence.location + 3, length: 0))
        view.renderMarkdown()
        XCTAssertGreaterThan((storage.attribute(.font, at: fence.location, effectiveRange: nil) as! NSFont).pointSize, 1)
        view.setSelectedRange(NSRange(location: code.location, length: 0))
        view.renderMarkdown()
        XCTAssertLessThan((storage.attribute(.font, at: fence.location, effectiveRange: nil) as! NSFont).pointSize, 1)
        view.liveEditing = false
        view.renderMarkdown()

        if let output = ProcessInfo.processInfo.environment["NOTES_CODE_BLOCK_SCREENSHOT"] {
            let canvas = NSBox(frame: view.bounds)
            canvas.boxType = .custom; canvas.borderType = .noBorder
            canvas.fillColor = .textBackgroundColor; canvas.contentViewMargins = .zero
            canvas.appearance = view.effectiveAppearance; canvas.contentView = view
            view.layoutManager?.ensureLayout(for: view.textContainer!)
            let bitmap = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
            canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output))
        }
    }
    @MainActor func testFencedBlockCanFoldWithoutChangingSource() throws {
        _ = NSApplication.shared
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 300))
        let view = MarkdownTextView(frame: scroll.bounds)
        scroll.documentView = view
        let source = "Before\n\n```text\n" + (1...30).map { "Artículo \($0). Organización, dirección y relación jurídica.\n" }.joined() + "```\n\nAfter\n"
        view.string = source
        view.liveEditing = false
        view.renderMarkdown()
        let layout = try XCTUnwrap(view.layoutManager)
        let container = try XCTUnwrap(view.textContainer)
        func height() -> CGFloat {
            layout.ensureLayout(for: container)
            return layout.usedRect(for: container).height
        }
        let expanded = height()
        let expandedFrame = view.frame.height
        view.toggleCodeBlock(at: 0)
        let folded = height()
        XCTAssertLessThan(folded, expanded - 100)
        XCTAssertLessThan(view.frame.height, expandedFrame - 100)
        XCTAssertEqual(view.string, source)
        view.toggleCodeBlock(at: 0)
        XCTAssertEqual(height(), expanded, accuracy: 1)
        XCTAssertEqual(view.string, source)
        view.liveEditing = true
        let fence = (source as NSString).range(of: "```text")
        view.setSelectedRange(NSRange(location: fence.location + 3, length: 0))
        view.renderMarkdown()
        if let output = ProcessInfo.processInfo.environment["NOTES_EXPANDED_BLOCK_SCREENSHOT"] {
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output))
        }
        view.liveEditing = false
        view.renderMarkdown()
        view.toggleCodeBlock(at: 0)
        view.liveEditing = true
        view.setSelectedRange(NSRange(location: source.utf16.count, length: 0))
        view.insertText("Tail", replacementRange: view.selectedRange())
        view.renderMarkdown()
        XCTAssertEqual(view.string, source + "Tail")
        XCTAssertLessThan(height(), expanded - 100)
        view.toggleCodeBlock(at: 0)
        view.setSelectedRange(NSRange(location: fence.location + 3, length: 0))
        view.renderMarkdown()
        view.toggleCodeBlock(at: 0)
        XCTAssertGreaterThan(view.selectedRange().location, (source as NSString).range(of: "```\n\nAfter").location + 3)
        XCTAssertLessThan((view.textStorage!.attribute(.font, at: fence.location, effectiveRange: nil) as! NSFont).pointSize, 1)
        XCTAssertEqual(view.string, source + "Tail")
        if let output = ProcessInfo.processInfo.environment["NOTES_FOLDED_BLOCK_SCREENSHOT"] {
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output))
        }
    }
    @MainActor func testEditingFenceRegeneratesGlyphsForNewFonts() throws {
        _ = NSApplication.shared
        let source = "Before\n\n```\nArtículo 3. Fuentes de la relación laboral.\n\nLos derechos y obligaciones: organización, dirección, jurídica.\n```\n\nAfter"
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
        let coordinator = LiveMarkdownEditor.Coordinator()
        coordinator.update(LiveMarkdownEditor(documentID: "glyphs", text: source, editing: true, onChange: { _ in }, onLink: { _ in }), scroll: scroll)
        let view = try XCTUnwrap(coordinator.editors["glyphs"])
        let layout = try XCTUnwrap(view.layoutManager)
        layout.ensureLayout(for: view.textContainer!)
        let opening = (source as NSString).range(of: "```\n")
        view.insertText("``", replacementRange: opening)
        view.renderMarkdown()
        layout.ensureLayout(for: view.textContainer!)

        let fresh = MarkdownTextView(frame: view.frame)
        fresh.string = view.string
        fresh.setSelectedRange(view.selectedRange())
        fresh.renderMarkdown()
        let freshLayout = try XCTUnwrap(fresh.layoutManager)
        freshLayout.ensureLayout(for: fresh.textContainer!)
        XCTAssertEqual(view.string, (source as NSString).replacingCharacters(in: opening, with: "``"))
        XCTAssertEqual(layout.numberOfGlyphs, freshLayout.numberOfGlyphs)
        for index in 0..<min(layout.numberOfGlyphs, freshLayout.numberOfGlyphs) {
            XCTAssertEqual(layout.glyph(at: index), freshLayout.glyph(at: index), "Stale glyph at \(index)")
        }
        if let output = ProcessInfo.processInfo.environment["NOTES_EDITED_FENCE_SCREENSHOT"] {
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output))
        }
    }
    @MainActor func testSingleLineFoldKeepsPreviewAndSource() throws {
        _ = NSApplication.shared
        let view = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 940, height: 220))
        view.appearance = NSAppearance(named: ProcessInfo.processInfo.environment["NOTES_FOLD_APPEARANCE"] == "dark" ? .darkAqua : .aqua)
        let source = "```text\nArtículo 1.1. Esta ley será de aplicación a los trabajadores que voluntariamente presten sus servicios retribuidos por cuenta ajena.\n```\n"
        view.string = source
        view.liveEditing = false
        view.renderMarkdown()
        let layout = try XCTUnwrap(view.layoutManager)
        let container = try XCTUnwrap(view.textContainer)
        layout.ensureLayout(for: container)
        let expanded = layout.usedRect(for: container).height
        view.toggleCodeBlock(at: 0)
        layout.ensureLayout(for: container)
        XCTAssertLessThan(layout.usedRect(for: container).height, expanded)
        XCTAssertEqual(view.string, source)
        if let output = ProcessInfo.processInfo.environment["NOTES_SINGLE_LINE_FOLD_SCREENSHOT"] {
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output))
        }
    }
    @MainActor func testListsAndComposition() throws {
        _ = NSApplication.shared
        let view = MarkdownTextView(frame: .zero)
        view.string = "1. acción"
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        view.insertNewline(nil)
        XCTAssertEqual(view.string, "1. acción\n2. ")
        view.insertNewline(nil)
        XCTAssertEqual(view.string, "1. acción\n")
        view.string = "- [x] uno"
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        view.insertNewline(nil)
        XCTAssertEqual(view.string, "- [x] uno\n- [ ] ")
        view.string = "Español: "
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        view.setMarkedText("accio\u{301}n", selectedRange: NSRange(location: 7, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let marked = view.string
        view.renderMarkdown()
        XCTAssertEqual(view.string, marked)
        XCTAssertTrue(view.hasMarkedText())
        view.unmarkText()
        view.renderMarkdown()
        XCTAssertEqual(view.string, "Español: accio\u{301}n")
    }
    @MainActor func testCoordinatorKeepsDocumentsAndModes() throws {
        _ = NSApplication.shared
        let coordinator = LiveMarkdownEditor.Coordinator()
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        var a = "# A\nTexto"
        func owner(_ id: String, _ text: String, _ edit: Bool) -> LiveMarkdownEditor {
            LiveMarkdownEditor(documentID: id, text: text, editing: edit, onChange: { a = $0 }, onLink: { _ in })
        }
        coordinator.update(owner("a", a, true), scroll: scroll)
        let first = coordinator.editors["a"]!
        first.setSelectedRange(NSRange(location: 3, length: 0))
        first.insertText("ñ", replacementRange: first.selectedRange())
        first.breakUndoCoalescing()
        let edited = first.string
        coordinator.update(owner("a", edited, false), scroll: scroll)
        XCTAssertFalse(first.isEditable)
        XCTAssertEqual(first.string, edited)
        coordinator.update(owner("b", "# B", true), scroll: scroll)
        coordinator.update(owner("a", edited, true), scroll: scroll)
        XCTAssertTrue(scroll.documentView === first)
        XCTAssertEqual(first.selectedRange().location, 4)
        first.undoManager?.undo()
        XCTAssertEqual(first.string, "# A\nTexto")
        first.setMarkedText("ñ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 3, length: 0))
        let composed = first.string
        coordinator.update(owner("b", "# B", true), scroll: scroll)
        coordinator.update(owner("a", composed, true), scroll: scroll)
        XCTAssertEqual(first.string, composed)
        first.unmarkText()
    }
    @MainActor func testDraftRefreshProtectionAndRender() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = ProcessInfo.processInfo.environment["NOTES_UI_QA_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".test-workspaces/NotesUI-" + UUID().uuidString)
        let fixture = root.appendingPathComponent("fixture")
        try FileManager.default.createDirectory(at: fixture.appendingPathComponent("copied-course/Temas"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixture.appendingPathComponent("session-storage"), withIntermediateDirectories: true)
        let workspace = try SafeWorkspace(root: fixture, originalRoot: root.appendingPathComponent("never-used-original"))
        let source = "# La relación de trabajo\n\n## Elementos esenciales\n\nLa **voluntariedad** y la *retribución* organizan esta nota de ejemplo.\n\n- Prestación personal\n- Dependencia y organización\n- Ajenidad en los resultados\n\n> Una idea para revisar antes de clase.\n\n## Próxima sesión\n\nConsultar [[Resumen|el resumen]] y comparar los conceptos.\n\n`Artículo de ejemplo` · Información completamente inventada.\n"
        try source.write(to: fixture.appendingPathComponent("copied-course/Temas/Relación laboral.md"), atomically: true, encoding: .utf8)
        try "# Resumen\n\nOtra nota inventada.".write(to: fixture.appendingPathComponent("copied-course/Resumen.md"), atomically: true, encoding: .utf8)
        let model = Workbench()
        model.errorText = nil
        model.workspace = workspace
        model.editor = try NotebookEditor(workspace: workspace)
        model.media = try MediaController(workspace: workspace)
        model.notes = try workspace.noteNames()
        model.folders = try workspace.folderNames()
        model.openNote("Temas/Relación laboral.md")
        model.changeDraft(source + "\nBorrador personal.")
        model.refreshEditorFromDisk()
        XCTAssertTrue(model.draftText.hasSuffix("Borrador personal."))
        model.openNote("Resumen.md")
        model.openNote("Temas/Relación laboral.md")
        XCTAssertTrue(model.draftText.hasSuffix("Borrador personal."))
        model.changeDraft(source)
        for dark in [false, true] {
            for editing in [false, true] {
                for width in [940, 1280] {
                    model.layout = editing ? "edit" : "preview"
                    let size = NSSize(width: width, height: width == 940 ? 620 : 820)
                    let host = NSHostingView(rootView: WorkbenchView(model: model).environment(\.colorScheme, dark ? .dark : .light))
                    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    window.contentView = host
                    host.frame = NSRect(origin: .zero, size: size)
                    host.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(200))
                    host.layoutSubtreeIfNeeded()
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    try png.write(to: root.appendingPathComponent("\(dark ? "dark" : "light")-\(editing ? "edit" : "view")-\(width).png"))
                    window.close()
                }
            }
        }
        XCTAssertEqual(try workspace.readNote("Temas/Relación laboral.md"), source)
        model.ai = try AIController(workspace: workspace, editor: model.editor!)
        model.createAIDemo()
        let job = try XCTUnwrap(model.media?.selected)
        let ai = try XCTUnwrap(model.ai)
        var batch = try ai.outbox.enqueue(media: job, selected: job.transcript)
        let response: [String: Any] = ["version": 1, "batch_id": batch.id, "decisions": [
            ["source_ids": ["s1"], "action": "correct", "text": "El concepto A utiliza dos pasos.", "reason": "Corrección inventada.", "target_quote": "El concepto A utiliza tres pasos."],
            ["source_ids": ["s2", "s3", "s4"], "action": "aside", "text": "", "reason": "Fixture local."]
        ]]
        batch.decisions = try OpenRouterHarness.decodeResponse(String(decoding: JSONSerialization.data(withJSONObject: response), as: UTF8.self), for: batch)
        batch.stage = .ready
        try ai.outbox.replace(batch)
        let proposal = try XCTUnwrap(batch.decisions.first)
        let personal = SyntheticAIFixture.note + "\nEdición personal sin guardar."
        model.changeDraft(personal)
        model.applyAI(batch: batch, proposal: proposal, text: proposal.text, quote: proposal.targetQuote)
        XCTAssertEqual(model.draftText, personal)
        XCTAssertEqual(try workspace.readNote(job.targetNote), SyntheticAIFixture.note)
        XCTAssertNotNil(model.errorText)
        model.ai?.stop()
        model.media?.shutdown()
    }
}
