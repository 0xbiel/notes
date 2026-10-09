import XCTest
import AppKit
import LectureCore
@testable import Notes

final class PalladiumRefinementTests: XCTestCase {
    @MainActor private func environment() throws -> (Workbench, URL) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".test-workspaces/Refinements-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("copied-course"), withIntermediateDirectories: true)
        try "# Inicio\n\nOriginal.\n".write(to: root.appendingPathComponent("copied-course/Inicio.md"), atomically: true, encoding: .utf8)
        try JSONSerialization.data(withJSONObject: ["originalRoot": root.appendingPathComponent("protected-original").path])
            .write(to: root.appendingPathComponent("original-hashes.json"))
        let model = Workbench(workspaceRoot: root)
        XCTAssertNil(model.errorText)
        return (model, root)
    }
    @MainActor private func clean(_ model: Workbench, _ root: URL) {
        for task in model.autosaveTasks.values { task.cancel() }
        model.assistant?.stop(); model.ai?.stop(); model.media?.shutdown()
        try? FileManager.default.removeItem(at: root)
    }

    @MainActor func testAutosaveDebouncesLatestDraftAndKeepsUndo() async throws {
        let (model, root) = try environment(); defer { clean(model, root) }
        let original = model.draftText
        model.changeDraft("First revision")
        try await Task.sleep(for: .milliseconds(300))
        model.changeDraft("Latest revision 👩🏽‍💻")
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(try model.workspace?.readNote("Inicio.md"), original)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(try model.workspace?.readNote("Inicio.md"), "Latest revision 👩🏽‍💻")
        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(model.editor?.history.last?.before, original)
        model.undoEditor()
        XCTAssertEqual(try model.workspace?.readNote("Inicio.md"), original)
    }

    @MainActor func testSwitchAndLifecycleFlushSaveCorrectDocuments() throws {
        let (model, root) = try environment(); defer { clean(model, root) }
        try model.workspace?.createNote("Second.md", text: "Second original")
        model.changeDraft("First saved automatically")
        model.openNote("Second.md")
        XCTAssertEqual(try model.workspace?.readNote("Inicio.md"), "First saved automatically")
        model.changeDraft("Second saved automatically")
        model.flushAutosave()
        XCTAssertEqual(try model.workspace?.readNote("Second.md"), "Second saved automatically")
        XCTAssertTrue(model.autosaveTasks.isEmpty)
        let restored = Workbench(workspaceRoot: root)
        defer { restored.media?.shutdown(); restored.ai?.stop() }
        restored.openNote("Second.md")
        XCTAssertEqual(restored.draftText, "Second saved automatically")
        XCTAssertFalse(restored.isDirty)
    }

    @MainActor func testAutosaveConflictRetainsDiskAndRecoverableDraft() async throws {
        let (model, root) = try environment(); defer { clean(model, root) }
        let original = model.draftText
        model.changeDraft("Unsaved local revision")
        try model.workspace?.writeNote("Inicio.md", expected: original, replacement: "External revision")
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(try model.workspace?.readNote("Inicio.md"), "External revision")
        XCTAssertEqual(model.draftText, "Unsaved local revision")
        XCTAssertTrue(model.isDirty)
        XCTAssertNotNil(model.errorText)
        let restored = Workbench(workspaceRoot: root)
        defer { restored.media?.shutdown(); restored.ai?.stop() }
        XCTAssertEqual(restored.draftText, "Unsaved local revision")
        XCTAssertEqual(try restored.workspace?.readNote("Inicio.md"), "External revision")
    }

    @MainActor func testUnderlineKeepsSourceRevealsTagsAndLeavesCodeLiteral() throws {
        _ = NSApplication.shared
        let view = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 400))
        let source = "<u>organismo **autónomo** 👩🏽‍💻</u>\n\n`<u>literal</u>`\n\n```html\n<u>fenced</u>\n```\n\n<u>unmatched"
        view.string = source; view.liveEditing = false; view.renderMarkdown()
        let ns = source as NSString, storage = try XCTUnwrap(view.textStorage)
        let body = ns.range(of: "organismo")
        XCTAssertEqual(storage.attribute(.underlineStyle, at: body.location, effectiveRange: nil) as? Int, NSUnderlineStyle.single.rawValue)
        XCTAssertLessThan((storage.attribute(.font, at: 0, effectiveRange: nil) as! NSFont).pointSize, 1)
        for literal in ["literal", "fenced", "unmatched"] {
            XCTAssertNil(storage.attribute(.underlineStyle, at: ns.range(of: literal).location, effectiveRange: nil))
        }
        view.liveEditing = true; view.setSelectedRange(body); view.renderMarkdown()
        XCTAssertGreaterThan((storage.attribute(.font, at: 0, effectiveRange: nil) as! NSFont).pointSize, 1)
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(view.selectedRange(), body)
        let chat = InlineUnderline.attributed("<u>organismo **autónomo** 👩🏽‍💻</u> y `<u>literal</u>`")
        XCTAssertEqual(String(chat.characters), "organismo autónomo 👩🏽‍💻 y <u>literal</u>")
        XCTAssertTrue(chat.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        let rendered = NSAttributedString(chat)
        XCTAssertEqual(rendered.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int, NSUnderlineStyle.single.rawValue)
        XCTAssertNil(rendered.attribute(.underlineStyle, at: (rendered.string as NSString).range(of: "literal").location, effectiveRange: nil))
    }

    @MainActor func testFloatingComposerInsetsPreserveDocumentScroll() async throws {
        _ = NSApplication.shared
        let scroll = MarkdownScrollView()
        let coordinator = LiveMarkdownEditor.Coordinator()
        let longNote = (1...80).map { "## Section \($0)\n\nInvented text for scrolling.\n" }.joined(separator: "\n")
        func owner(_ id: String, inset: CGFloat) -> LiveMarkdownEditor {
            LiveMarkdownEditor(documentID: id, text: longNote, editing: false, bottomInset: inset, onChange: { _ in }, onLink: { _ in })
        }
        coordinator.update(owner("first", inset: 130), scroll: scroll)
        scroll.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        scroll.layoutSubtreeIfNeeded()
        coordinator.update(owner("first", inset: 130), scroll: scroll)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(scroll.documentView?.frame.origin.y, 0)
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 0, accuracy: 1)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 350))
        coordinator.update(owner("first", inset: 410), scroll: scroll)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 350, accuracy: 1)
        coordinator.update(owner("second", inset: 130), scroll: scroll)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 0, accuracy: 1)
        coordinator.update(owner("first", inset: 130), scroll: scroll)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(scroll.contentView.bounds.origin.y, 350, accuracy: 1)
    }

    @MainActor func testCommonMarkdownEmphasisPreservesNestedStylesAndLiteralUnderscores() throws {
        _ = NSApplication.shared
        let view = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 400))
        let source = "_cursiva_ __negrita__ ___ambas___ ***también*** **fuerte _mixta_** _suave **combinada**_ <u>__subrayada__</u>\n\nsnake_case_name \\_escapada\\_ `_código_` _ sin formato _"
        view.string = source; view.liveEditing = false; view.renderMarkdown()
        let storage = try XCTUnwrap(view.textStorage), text = source as NSString
        func traits(_ word: String) -> NSFontTraitMask {
            let font = storage.attribute(.font, at: text.range(of: word).location, effectiveRange: nil) as! NSFont
            return NSFontManager.shared.traits(of: font)
        }
        XCTAssertTrue(traits("cursiva").contains(.italicFontMask))
        XCTAssertTrue(traits("negrita").contains(.boldFontMask))
        for word in ["ambas", "también", "mixta", "combinada"] {
            XCTAssertTrue(traits(word).contains(.italicFontMask), word)
            XCTAssertTrue(traits(word).contains(.boldFontMask), word)
        }
        XCTAssertTrue(traits("subrayada").contains(.boldFontMask))
        XCTAssertEqual(storage.attribute(.underlineStyle, at: text.range(of: "subrayada").location, effectiveRange: nil) as? Int, NSUnderlineStyle.single.rawValue)
        for word in ["case", "escapada", "código", "sin formato"] { XCTAssertFalse(traits(word).contains(.italicFontMask), word) }
        XCTAssertEqual(view.string, source)
        view.liveEditing = true; view.setSelectedRange(text.range(of: "cursiva")); view.renderMarkdown()
        XCTAssertGreaterThan((storage.attribute(.font, at: 0, effectiveRange: nil) as! NSFont).pointSize, 1)
        let chat = InlineUnderline.attributed("_cursiva_ __negrita__ ___ambas___")
        XCTAssertEqual(String(chat.characters), "cursiva negrita ambas")
    }

    @MainActor func testCatalogPersistsReloadsAndIgnoresModelSelectionChanges() async throws {
        let (model, root) = try environment(); defer { clean(model, root) }
        let workspace = try XCTUnwrap(model.workspace)
        var calls = 0
        let fixture = [AIProviderModel(id: "fixture", name: "Fixture model", reasoning: ["low", "high"])]
        let cache = ProviderCatalogStore(workspace: workspace) { _ in calls += 1; return fixture }
        var configuration = AIProviderSettings().codexCLI
        _ = try await cache.refresh(configuration)
        configuration.model = "another-model"; configuration.reasoningEffort = "high"
        _ = try await cache.refresh(configuration)
        XCTAssertEqual(calls, 1)
        let restored = ProviderCatalogStore(workspace: workspace) { _ in XCTFail("Fresh persisted catalog must not fetch"); return [] }
        XCTAssertEqual(restored.models(for: configuration), fixture)
        _ = try await restored.refresh(configuration)
        configuration.homePath = "/different/account"
        XCTAssertNil(restored.models(for: configuration))
    }

    @MainActor func testCatalogCoalescesRefreshesAndRetainsStaleModelsOnFailure() async throws {
        let (model, root) = try environment(); defer { clean(model, root) }
        var calls = 0, fail = false
        let fixture = [AIProviderModel(id: "fixture", name: "Fixture")]
        let cache = ProviderCatalogStore(workspace: try XCTUnwrap(model.workspace)) { _ in
            calls += 1
            try await Task.sleep(for: .milliseconds(40))
            if fail { throw MediaError.invalid("Temporarily offline") }
            return fixture
        }
        let configuration = AIProviderSettings().codexCLI
        let first = Task { try await cache.refresh(configuration) }
        let second = Task { try await cache.refresh(configuration) }
        _ = try await first.value; _ = try await second.value
        XCTAssertEqual(calls, 1)
        fail = true
        let stale = Date().addingTimeInterval(ProviderCatalogStore.refreshInterval + 1)
        do { _ = try await cache.refresh(configuration, now: stale); XCTFail("Expected refresh failure") } catch { }
        XCTAssertEqual(cache.models(for: configuration), fixture)
        _ = try await cache.refresh(configuration, now: stale.addingTimeInterval(1))
        XCTAssertEqual(calls, 2, "A failed refresh should back off instead of refetching whenever a selector opens")
        fail = false
        _ = try await cache.refresh(configuration, force: true)
        XCTAssertEqual(calls, 3)
    }

    @MainActor func testPreferencesSharePublishedCatalogAndReopenWithModels() async throws {
        let (model, root) = try environment(); defer { clean(model, root) }
        let ai = try XCTUnwrap(model.ai)
        let first = ProviderPreferencesModel(ai: ai), second = ProviderPreferencesModel(ai: ai)
        // OpenCode's catalog is local fixed metadata; no account/API probe.
        _ = try await ai.modelCatalogs.refresh(ai.providerSettings.openCode)
        XCTAssertFalse(first.models.isEmpty)
        XCTAssertEqual(first.models, second.models)
        let reopened = ProviderPreferencesModel(ai: ai)
        XCTAssertEqual(first.models, reopened.models)
    }
}
