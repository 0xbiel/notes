import XCTest
import SwiftUI
import LectureCore
@testable import Notes

final class NotebookAssistantTests: XCTestCase {
    @MainActor private func fixture() throws -> (Workbench, NotebookAssistantController, URL) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".test-workspaces/NotebookAssistant-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("copied-course"), withIntermediateDirectories: true)
        try Data("# Inicio\n\nTexto inicial.\n".utf8).write(to: root.appendingPathComponent("copied-course/Inicio.md"))
        try JSONSerialization.data(withJSONObject: ["originalRoot": root.appendingPathComponent("original").path]).write(to: root.appendingPathComponent("original-hashes.json"))
        let model = Workbench(workspaceRoot: root)
        XCTAssertNil(model.errorText)
        let assistant = try XCTUnwrap(model.assistant)
        model.openNote("Inicio.md")
        addTeardownBlock { @MainActor in model.assistant?.stop(); model.ai?.stop(); model.media?.shutdown(); try? FileManager.default.removeItem(at: root) }
        return (model, assistant, root)
    }
    @MainActor func testPastedImageAndFileStayWithTheirOriginalChat() async throws {
        let (model, assistant, root) = try fixture()
        let notebook = model.currentNotebook
        let first = try assistant.newChat(notebook)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let url = root.appendingPathComponent("copied-course/Inicio.md")
        assistant.pasteAttachments([
            NSItemProvider(item: data as NSData, typeIdentifier: "public.png"),
            NSItemProvider(item: Data(url.absoluteString.utf8) as NSData, typeIdentifier: "public.file-url")
        ], notebook: notebook)
        for _ in 0..<300 {
            if !assistant.importingAttachments { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(assistant.importingAttachments)
        XCTAssertNil(assistant.error)
        XCTAssertEqual(assistant.chat(notebook)?.attachments?.count, 2)
        XCTAssertEqual(assistant.chat(notebook)?.id, first)
        let second = try assistant.newChat(notebook)
        XCTAssertNotEqual(first, second)
        XCTAssertNil(assistant.chat(notebook)?.attachments)
        assistant.selectChat(first, notebook: notebook)
        let attached = try XCTUnwrap(assistant.chat(notebook)?.attachments)
        assistant.removeAttachment(attached[0].id, notebook: notebook)
        XCTAssertEqual(assistant.chat(notebook)?.attachments?.count, 1)
    }
    @MainActor func testAttachmentDraftPersistenceAndAttachmentOnlySend() async throws {
        let (model, assistant, _) = try fixture()
        let notebook = model.currentNotebook
        let chatID = try assistant.newChat(notebook)
        let attachment = try NotebookAttachmentImport.prepare(data: Data("Invented attachment context".utf8), name: "Context.txt", notebookID: notebook.id, workspace: assistant.store.workspace)
        try assistant.addAttachments([attachment], notebook: notebook, chatID: chatID)
        XCTAssertTrue(assistant.matchingChats(notebook, query: "").isEmpty)
        let persisted = try NotebookAssistantController(store: assistant.store)
        XCTAssertEqual(persisted.chat(notebook)?.attachments, [attachment])
        assistant.generate = { request, _ in
            XCTAssertEqual(request.messages.last?.attachments?.first?.text, "Invented attachment context")
            return .init(reply: "Read the attachment")
        }
        model.submitNotebookPrompt(); await assistant.waitUntilFinished()
        XCTAssertNil(assistant.error)
        XCTAssertNil(assistant.chat(notebook)?.attachments)
        XCTAssertEqual(assistant.chat(notebook)?.messages.first?.attachments, [attachment])
        XCTAssertEqual(assistant.matchingChats(notebook, query: "").count, 1)
    }
    @MainActor func testEmptyChatsStayTemporaryAndReuseBlankSession() throws {
        let (model, assistant, _) = try fixture()
        let notebook = model.currentNotebook
        let first = try assistant.newChat(notebook)
        XCTAssertEqual(try assistant.newChat(notebook), first)
        XCTAssertTrue(assistant.matchingChats(notebook, query: "").isEmpty)
        XCTAssertTrue(try assistant.store.loadState(notebook).chats.isEmpty)
        assistant.setDraft("Unsent work", notebook: notebook)
        let saved = try assistant.store.loadState(notebook)
        XCTAssertTrue(saved.chats.isEmpty)
        XCTAssertEqual(saved.pendingDrafts?.first?.draft, "Unsent work")
        let reopened = try NotebookAssistantController(store: assistant.store)
        XCTAssertEqual(reopened.chat(notebook)?.draft, "Unsent work")
        XCTAssertTrue(reopened.matchingChats(notebook, query: "").isEmpty)
    }
    @MainActor func testChatSearchDeletionAndPersistence() throws {
        let (model, assistant, _) = try fixture()
        let notebook = model.currentNotebook
        let first = try assistant.newChat(notebook)
        var value = assistant.state(notebook)
        value.chats[0].title = "Labour overview"
        value.chats[0].messages = [.init(role: "assistant", text: "Collective agreements")]
        try assistant.store.saveState(value, notebookID: notebook.id)
        let reloaded = try NotebookAssistantController(store: assistant.store)
        XCTAssertEqual(reloaded.matchingChats(notebook, query: "COLLECTIVE").map(\.id), [first])
        XCTAssertTrue(reloaded.matchingChats(notebook, query: "missing").isEmpty)
        let second = try reloaded.newChat(notebook)
        try reloaded.deleteChat(second, notebook: notebook)
        XCTAssertEqual(reloaded.chat(notebook)?.id, first)
        try reloaded.deleteChat(first, notebook: notebook)
        XCTAssertNil(reloaded.chat(notebook))
        XCTAssertTrue(try assistant.store.loadState(notebook).chats.isEmpty)
        XCTAssertTrue(model.notes.contains("Inicio.md"))
    }
    @MainActor func testNotebookSelectionNewEmptyNotebookAndPersistedChatProfile() throws {
        let (model, assistant, root) = try fixture()
        model.changeDraft("Unchanged draft")
        model.openNotebook("derecho")
        XCTAssertNil(model.selectedNote); XCTAssertEqual(model.drafts["Inicio.md"], "Unchanged draft")
        assistant.setDraft("First draft", notebook: model.currentNotebook)
        let firstChat = try XCTUnwrap(assistant.chat(model.currentNotebook)).id
        try assistant.newChat(model.currentNotebook)
        assistant.setDraft("Second draft", notebook: model.currentNotebook)
        assistant.selectChat(firstChat, notebook: model.currentNotebook)
        XCTAssertEqual(assistant.chat(model.currentNotebook)?.draft, "First draft")
        var profile = assistant.state(model.currentNotebook).profile; profile.instructions = "Use outlines"
        assistant.saveProfile(profile, notebook: model.currentNotebook)
        try model.createNotebookItem(kind: "cuaderno", name: "Other")
        XCTAssertNil(model.selectedNote); XCTAssertTrue(model.noteNames(in: model.currentNotebook).isEmpty)
        XCTAssertNil(assistant.chat(model.currentNotebook))
        let reopened = Workbench(workspaceRoot: root)
        defer { reopened.ai?.stop(); reopened.media?.shutdown() }
        reopened.openNotebook("derecho")
        XCTAssertEqual(reopened.assistant?.chat(reopened.currentNotebook)?.draft, "First draft")
        XCTAssertEqual(reopened.assistant?.state(reopened.currentNotebook).profile.instructions, "Use outlines")
    }
    @MainActor func testDirectMultiFileEditDraftCheckpointAndRestore() async throws {
        let (model, assistant, root) = try fixture()
        model.changeDraft("# Inicio\n\nMi borrador.\n")
        assistant.setDraft("Edit and create", notebook: model.currentNotebook)
        assistant.generate = { request, _ in
            XCTAssertEqual(request.currentDocument, "Inicio.md")
            return .init(reply: "Done", edits: [.init(path: "Inicio.md", find: "Mi borrador.", replacement: "Mi borrador editado."), .init(path: "Nueva.md", replacement: "# Nueva\n", create: true)])
        }
        model.submitNotebookPrompt(); await assistant.waitUntilFinished()
        XCTAssertNil(assistant.error)
        XCTAssertEqual(model.draftText, "# Inicio\n\nMi borrador editado.\n")
        let timeline = try XCTUnwrap(model.projects).timeline("derecho")
        let draft = try XCTUnwrap(timeline.first { $0.summary == "Borradores guardados" })
        let edited = try XCTUnwrap(timeline.last)
        XCTAssertEqual(edited.changedFiles, ["Inicio.md", "Nueva.md"])
        model.restoreCheckpoint(draft)
        XCTAssertEqual(model.draftText, "# Inicio\n\nMi borrador.\n")
        XCTAssertFalse(model.notes.contains("Nueva.md"))
        model.restoreCheckpoint(edited)
        XCTAssertTrue(model.notes.contains("Nueva.md"))
        let reopened = Workbench(workspaceRoot: root)
        defer { reopened.media?.shutdown(); reopened.ai?.stop() }
        XCTAssertEqual(reopened.assistant?.chat(.copiedCourse)?.messages.last?.files.count, 2)
    }
    @MainActor func testInterveningTypingBlocksAssistantAndKeepsDraft() async throws {
        let (model, assistant, _) = try fixture()
        assistant.setDraft("Edit", notebook: model.currentNotebook)
        assistant.generate = { _, _ in
            model.changeDraft("Typed while waiting")
            return .init(reply: "Done", edits: [.init(path: "Inicio.md", find: "Texto inicial.", replacement: "Changed")])
        }
        model.submitNotebookPrompt(); await assistant.waitUntilFinished()
        XCTAssertNotNil(assistant.error); XCTAssertEqual(model.draftText, "Typed while waiting")
        XCTAssertEqual(try model.workspace?.readNote("Inicio.md"), "# Inicio\n\nTexto inicial.\n")
    }
    @MainActor func testNotebookSwitchDoesNotRedirectInFlightEditsAndContextExcludesSibling() async throws {
        let (model, assistant, _) = try fixture()
        try model.createNotebookItem(kind: "cuaderno", name: "Other")
        let other = model.currentNotebook
        try model.workspace?.createNote(other.rootPrefix + "/Secret.md", text: "Other notebook data")
        model.openNotebook("derecho")
        assistant.setDraft("Update notes", notebook: model.currentNotebook)
        assistant.generate = { request, _ in
            XCTAssertNil(request.catalog[other.rootPrefix + "/Secret.md"])
            model.openNotebook(other.id)
            return .init(reply: "Done", edits: [.init(path: "Inicio.md", find: "Texto inicial.", replacement: "Updated")])
        }
        model.submitNotebookPrompt(); await assistant.waitUntilFinished()
        XCTAssertNil(assistant.error); XCTAssertEqual(model.selectedNotebookID, other.id); XCTAssertNil(model.selectedNote)
        XCTAssertTrue(try model.workspace!.readNote("Inicio.md").contains("Updated"))
        XCTAssertEqual(assistant.chat(.copiedCourse)?.messages.last?.role, "assistant")
        XCTAssertNil(assistant.chat(other))
    }
    @MainActor func testRequestsAdditionalFilesAndExactLegalSource() async throws {
        let (model, assistant, _) = try fixture()
        for name in ["A", "B", "C", "D", "Z"] { try model.workspace?.createNote(name + ".md", text: "# \(name)\n") }
        assistant.setDraft("Añade Art. 13 del Estatuto de los Trabajadores", notebook: model.currentNotebook)
        var round = 0
        assistant.fetchArticle = { query in XCTAssertEqual(query.article, "13"); return "Exact legal text with BOE citation" }
        assistant.generate = { request, _ in
            round += 1
            if round == 1 { return .init(reply: "", readFiles: ["Z.md"], articles: [.init(lawID: "BOE-A-2015-11430", lawName: "Estatuto de los Trabajadores", article: "13")]) }
            XCTAssertEqual(request.documents["Z.md"], "# Z\n")
            return .init(reply: "Added", edits: [.init(path: "Z.md", find: "# Z\n", replacement: "# Z\n\n{{article:0}}")])
        }
        model.submitNotebookPrompt(); await assistant.waitUntilFinished()
        XCTAssertNil(assistant.error); XCTAssertEqual(round, 2)
        let activities = try XCTUnwrap(assistant.chat(model.currentNotebook)?.messages.last?.activities)
        XCTAssertTrue(activities.contains { $0.title.contains("BOE") })
        XCTAssertTrue(activities.contains { $0.title.contains("Z.md") })
        XCTAssertTrue(activities.last?.title.contains("1 archivo") == true)
        XCTAssertNil(assistant.runningChatID)
        XCTAssertTrue(try model.workspace!.readNote("Z.md").contains("Exact legal text with BOE citation"))
    }
    @MainActor func testAmbiguityLookupFailureAndCancellationLeaveNotesUntouched() async throws {
        let (model, assistant, _) = try fixture()
        let initial = try model.workspace!.readNote("Inicio.md")
        assistant.setDraft("Art. 13", notebook: model.currentNotebook)
        assistant.generate = { _, _ in .init(reply: "¿De qué ley?") }
        model.submitNotebookPrompt(); await assistant.waitUntilFinished()
        XCTAssertEqual(assistant.chat(model.currentNotebook)?.messages.last?.text, "¿De qué ley?")
        assistant.setDraft("Art. 13 del Estatuto", notebook: model.currentNotebook)
        assistant.generate = { _, _ in .init(reply: "", articles: [.init(lawID: "BOE-A-2015-11430", lawName: "Estatuto", article: "13")]) }
        assistant.fetchArticle = { _ in throw MediaError.invalid("Offline") }
        model.submitNotebookPrompt(); await assistant.waitUntilFinished()
        XCTAssertEqual(assistant.error, "Offline")
        assistant.setDraft("Edit everything", notebook: model.currentNotebook)
        assistant.generate = { _, _ in try await Task.sleep(for: .seconds(30)); return .init(reply: "Too late") }
        model.submitNotebookPrompt(); assistant.stop(); await assistant.waitUntilFinished()
        XCTAssertEqual(try model.workspace!.readNote("Inicio.md"), initial)
        XCTAssertEqual(assistant.error, "Petición cancelada.")
    }
    @MainActor func testSessionNoteUsesCapturedNotebookAndUniqueNames() throws {
        let (model, _, _) = try fixture()
        try model.createNotebookItem(kind: "cuaderno", name: "Other")
        let captured = model.currentNotebook
        model.openNotebook("derecho")
        let first = try model.sessionNote(in: captured), second = try model.sessionNote(in: captured)
        XCTAssertTrue(first.hasPrefix(captured.rootPrefix + "/")); XCTAssertNotEqual(first, second)
        XCTAssertEqual(model.selectedNotebookID, "derecho"); XCTAssertNil(model.selectedNote)
    }
    @MainActor func testNotebookRenderAtWideAndNarrowSizes() async throws {
        let (model, assistant, _) = try fixture()
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("qa/notebook-workspaces")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for dark in [false, true] {
            for home in [true, false] {
                for width in [600, 1280] {
                    if home { model.openNotebook("derecho") } else { model.openNote("Inicio.md"); model.layout = "edit" }
                    assistant.setDraft(home ? "" : Array(repeating: "A longer request that wraps and grows without hiding the document.", count: 5).joined(separator: "\n"), notebook: model.currentNotebook)
                    let size = NSSize(width: width, height: width == 600 ? 650 : 820)
                    let host = NSHostingView(rootView: WorkbenchView(model: model).environment(\.colorScheme, dark ? .dark : .light))
                    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    window.contentView = host; host.frame = NSRect(origin: .zero, size: size)
                    host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(200)); host.layoutSubtreeIfNeeded()
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("\(home ? "home" : "document")-\(dark ? "dark" : "light")-\(width).png"))
                    window.close()
                }
            }
        }
    }
    @MainActor func testRestoreInvalidatesOldTranscriptProposalAndLegacyUndo() throws {
        let (model, _, _) = try fixture()
        let baseline = try XCTUnwrap(model.projects?.timeline("derecho").first)
        model.changeDraft("Manual version"); model.saveDraft()
        let ai = try XCTUnwrap(model.ai)
        var media = MediaJob(notebookID: "derecho", subject: "Invented", note: "Inicio.md", sourceName: "Invented")
        media.transcript = [.init(id: "s", start: 0, end: 1, text: "Invented speech")]
        let batch = try ai.outbox.enqueue(media: media, selected: media.transcript)
        model.restoreCheckpoint(baseline)
        XCTAssertTrue(ai.outbox.batches.first { $0.id == batch.id }?.invalidatedByNotebook == true)
        XCTAssertTrue(model.editor?.history.first?.superseded == true)
        XCTAssertThrowsError(try model.editor?.undo())
    }

    @MainActor func testRedundantRetrievalGetsExplicitContextBeforeRetry() async throws {
        let (model, assistant, _) = try fixture()
        assistant.setDraft("Revise introduction", notebook: model.currentNotebook)
        var round = 0
        assistant.generate = { request, _ in
            round += 1
            if round == 1 { return .init(reply: "", readFiles: ["Inicio.md"]) }
            XCTAssertTrue(request.contextUpdate.contains("Inicio.md"))
            return .init(reply: "Done", edits: [.init(path: "Inicio.md", find: "Texto inicial.", replacement: "Updated.")])
        }
        model.submitNotebookPrompt(); await assistant.waitUntilFinished()
        XCTAssertNil(assistant.error)
        XCTAssertEqual(round, 2)
        XCTAssertTrue(model.draftText.contains("Updated."))
    }

    @MainActor func testDeleteDraftAndRestoreFromTrashAfterRestart() throws {
        let (model, _, root) = try fixture()
        model.changeDraft("Unsaved work")
        model.deleteItem("Inicio.md", folder: false)
        XCTAssertNil(model.errorText)
        XCTAssertFalse(model.notes.contains("Inicio.md"))
        XCTAssertNil(model.selectedNote)
        XCTAssertEqual(model.trash.count, 1)
        let reopened = Workbench(workspaceRoot: root)
        defer { reopened.ai?.stop(); reopened.media?.shutdown() }
        XCTAssertNil(reopened.errorText)
        reopened.restoreTrash(try XCTUnwrap(reopened.trash.first))
        XCTAssertEqual(try reopened.workspace?.readNote("Inicio.md"), "Unsaved work")
        XCTAssertTrue(reopened.trash.isEmpty)
    }
    @MainActor func testTrashRestoreRefusesNewerFileAtSamePath() throws {
        let (model, _, _) = try fixture()
        model.deleteItem("Inicio.md", folder: false)
        let entry = try XCTUnwrap(model.trash.first)
        try model.workspace?.createNote("Inicio.md", text: "Newer work")
        model.restoreTrash(entry)
        XCTAssertNotNil(model.errorText)
        XCTAssertEqual(try model.workspace?.readNote("Inicio.md"), "Newer work")
        XCTAssertEqual(model.trash.count, 1)
    }
    @MainActor func testFolderDeleteAndRestoreKeepsEmptyNestedFolders() throws {
        let (model, _, _) = try fixture()
        try model.createNotebookItem(kind: "carpeta", name: "Unit/Empty")
        try model.createNotebookItem(kind: "nota", name: "Unit/Notes")
        model.deleteItem("Unit", folder: true)
        XCTAssertNil(model.errorText)
        XCTAssertFalse(model.folders.contains("Unit"))
        XCTAssertFalse(model.notes.contains("Unit/Notes.md"))
        model.restoreTrash(try XCTUnwrap(model.trash.first))
        XCTAssertTrue(model.folders.contains("Unit/Empty"))
        XCTAssertTrue(model.notes.contains("Unit/Notes.md"))
    }
    @MainActor func testNotebookTrashPreservesChatsAndOwnershipAcrossRestart() throws {
        let (model, assistant, root) = try fixture()
        try model.createNotebookItem(kind: "cuaderno", name: "Other")
        let other = model.currentNotebook
        try model.createNotebookItem(kind: "nota", name: "Private")
        assistant.setDraft("Keep this chat", notebook: other)
        model.deleteNotebook(other)
        XCTAssertEqual(model.activeNotebooks.count, 1)
        XCTAssertFalse(model.noteNames(in: .copiedCourse).contains(other.rootPrefix + "/Private.md"))
        XCTAssertFalse(model.visibleNotes.contains(other.rootPrefix + "/Private.md"))
        XCTAssertThrowsError(try model.projects?.validate(other.rootPrefix + "/Private.md", notebookID: other.id))
        let reopened = Workbench(workspaceRoot: root)
        defer { reopened.ai?.stop(); reopened.media?.shutdown() }
        XCTAssertEqual(reopened.activeNotebooks.count, 1)
        reopened.restoreNotebook(other)
        XCTAssertEqual(reopened.assistant?.chat(other)?.draft, "Keep this chat")
        XCTAssertTrue(reopened.visibleNotes.contains(other.rootPrefix + "/Private.md"))
        for notebook in reopened.activeNotebooks { reopened.deleteNotebook(notebook) }
        XCTAssertTrue(reopened.activeNotebooks.isEmpty)
        XCTAssertNil(reopened.selectedNote)
        try reopened.createNotebookItem(kind: "cuaderno", name: "Fresh")
        XCTAssertEqual(reopened.currentNotebook.name, "Fresh")
    }
    @MainActor func testFolderDeletionRejectsOtherAssetsAndNotebookRoots() throws {
        let (model, _, root) = try fixture()
        try model.createNotebookItem(kind: "carpeta", name: "Assets")
        try Data("Keep".utf8).write(to: root.appendingPathComponent("copied-course/Assets/file.txt"))
        model.deleteItem("Assets", folder: true)
        XCTAssertNotNil(model.errorText)
        XCTAssertTrue(model.trash.isEmpty)
        try model.createNotebookItem(kind: "cuaderno", name: "Other")
        model.deleteItem("Cuadernos", folder: true)
        XCTAssertNotNil(model.errorText)
        XCTAssertEqual(model.activeNotebooks.count, 2)
    }

}
