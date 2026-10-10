import XCTest
import SwiftUI
import PDFKit
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
    @MainActor func testChatNavigatorGroupsRepliesAndTracksVisibleExchange() {
        let first = NotebookMessage(role: "user", text: "First question")
        let reply = NotebookMessage(role: "assistant", text: "First reply")
        let second = NotebookMessage(role: "user", text: "Second question")
        let error = NotebookMessage(role: "error", text: "Retry needed")
        let turns = NotebookChatTurn.collect([first, reply, second, error])
        XCTAssertEqual(turns.map(\.id), [first.id, second.id])
        XCTAssertEqual(turns.map(\.reply), ["First reply", "Retry needed"])
        XCTAssertEqual(NotebookChatTurn.active(in: [reply.id: CGRect(x: 0, y: -20, width: 200, height: 200), second.id: CGRect(x: 0, y: 200, width: 200, height: 80)], turns: turns), first.id)
        XCTAssertEqual(NotebookChatTurn.active(in: [reply.id: CGRect(x: 0, y: -200, width: 200, height: 200), second.id: CGRect(x: 0, y: 20, width: 200, height: 80)], turns: turns), second.id)
        let frames = [reply.id: CGRect(x: 0, y: -20, width: 200, height: 200),
                      second.id: CGRect(x: 0, y: 200, width: 200, height: 80)]
        XCTAssertEqual(NotebookChatTurn.visible(in: frames, turns: turns, height: 250), [first.id, second.id])
        XCTAssertEqual(NotebookChatTurn.visible(in: frames, turns: turns, height: 200), [first.id])
        XCTAssertEqual(NotebookChatTurn.visible(in: [reply.id: CGRect(x: 0, y: -200, width: 200, height: 200), second.id: frames[second.id]!], turns: turns, height: 250), [second.id])
        XCTAssertTrue(NotebookChatTurn.visible(in: frames, turns: turns, height: 0).isEmpty)
        XCTAssertTrue(NotebookChatTurn.collect([]).isEmpty)
    }

    @MainActor func testAssistantExplicitDeletionUpdatesLibraryAndCanBeRestored() async throws {
        let (model, assistant, _) = try fixture()
        let notebook = model.currentNotebook
        let initial = try model.projects!.capture(notebook.id, summary: "Before")
        assistant.generate = { _, _ in .init(reply: "Deleted the requested note.", edits: [.init(path: "Inicio.md", replacement: "", delete: true)]) }
        assistant.setDraft("Delete Inicio.md", notebook: notebook)
        model.submitNotebookPrompt(); await assistant.waitUntilFinished()
        XCTAssertFalse(model.notes.contains("Inicio.md"))
        XCTAssertNil(model.selectedNote)
        XCTAssertEqual(assistant.chat(notebook)?.messages.last?.role, "assistant")
        model.restoreCheckpoint(initial)
        XCTAssertTrue(model.notes.contains("Inicio.md"))
        XCTAssertEqual(try model.workspace!.readNote("Inicio.md"), "# Inicio\n\nTexto inicial.\n")
        assistant.setDraft("Summarize Inicio.md. Do not delete it.", notebook: notebook)
        model.submitNotebookPrompt(); await assistant.waitUntilFinished()
        XCTAssertTrue(model.notes.contains("Inicio.md"))
        XCTAssertEqual(assistant.chat(notebook)?.messages.last?.role, "error")
    }

    @MainActor func testRetryHonoursEarlierUserDeletionRequest() async throws {
        let (model, assistant, _) = try fixture()
        let notebook = model.currentNotebook
        assistant.generate = { _, _ in .init(reply: "Deletion was unavailable previously.") }
        assistant.setDraft("Delete Inicio.md", notebook: notebook)
        model.submitNotebookPrompt(); await assistant.waitUntilFinished()
        assistant.generate = { _, _ in .init(reply: "Deleted.", edits: [.init(path: "Inicio.md", replacement: "", delete: true)]) }
        assistant.setDraft("I want you to try again", notebook: notebook)
        model.submitNotebookPrompt(); await assistant.waitUntilFinished()
        XCTAssertFalse(model.notes.contains("Inicio.md"))
        XCTAssertEqual(assistant.chat(notebook)?.messages.last?.role, "assistant")
        try assistant.newChat(notebook)
        XCTAssertFalse(NotebookAssistantProtocol.deletionAllowed(in: assistant.chat(notebook)!.messages))
    }

    @MainActor func testImportedPreviewComposerVisibilityAndSelectedSourceContext() async throws {
        let (model, assistant, _) = try fixture()
        let initial = try model.workspace!.readNote("Inicio.md")
        try model.workspace!.createAsset("Guide.txt", data: Data("Invented source about automata.".utf8))
        model.refreshProjectFiles(["Guide.txt"])
        model.openLibraryFile("Guide.txt")
        model.layout = "edit" // A previous Markdown editing mode must not override the preview toggle.
        XCTAssertTrue(model.showsDocumentComposer)
        model.hideStudyComposer = true
        XCTAssertFalse(model.showsDocumentComposer)
        model.hideStudyComposer = false
        XCTAssertTrue(model.showsDocumentComposer)
        assistant.setDraft("Summarize this source", notebook: model.currentNotebook)
        var rounds = 0
        assistant.generate = { request, _ in
            XCTAssertEqual(request.currentDocument, "Guide.txt")
            rounds += 1
            if rounds == 1 { return .init(reply: "", readFiles: ["Guide.txt"]) }
            XCTAssertTrue(request.documents["Guide.txt"]?.contains("automata") == true)
            return .init(reply: "This source describes automata.")
        }
        model.submitNotebookPrompt(); await assistant.waitUntilFinished()
        XCTAssertNil(assistant.error)
        XCTAssertEqual(rounds, 2)
        XCTAssertEqual(try model.workspace!.readNote("Inicio.md"), initial)
        model.openNote("Inicio.md"); model.layout = "preview"; model.hideStudyComposer = true
        XCTAssertFalse(model.showsDocumentComposer)
        model.layout = "edit"
        XCTAssertFalse(model.showsDocumentComposer)
        model.hideStudyComposer = false
        XCTAssertTrue(model.showsDocumentComposer)
        model.openNotebook(model.selectedNotebookID)
        XCTAssertFalse(model.showsDocumentComposer)
    }

    @MainActor func testImportedPreviewRendersWithAndWithoutComposer() async throws {
        let (model, assistant, _) = try fixture()
        _ = NSApplication.shared
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 650))
        text.string = "Invented document\n\nA source about deterministic automata."
        try model.workspace!.createAsset("Guide.pdf", data: text.dataWithPDF(inside: text.bounds))
        let docx = try NSAttributedString(string: text.string).data(from: NSRange(location: 0, length: text.string.utf16.count), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        try model.workspace!.createAsset("Guide.docx", data: docx)
        model.refreshProjectFiles(["Guide.pdf", "Guide.docx"])
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("qa/imported-previews")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for path in ["Guide.pdf", "Guide.docx"] {
            for hidden in [false, true] {
                model.openLibraryFile(path); model.hideStudyComposer = hidden
                assistant.setDraft("Explain this document", notebook: model.currentNotebook)
                XCTAssertEqual(model.showsDocumentComposer, !hidden)
                let size = NSSize(width: 1100, height: 780)
                let host = NSHostingView(rootView: WorkbenchView(model: model))
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = host; host.frame = NSRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(350)); host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(path + (hidden ? "-hidden.png" : "-chat.png")))
                window.close()
            }
        }
    }

    @MainActor func testImportedSourceRetrievalCreatesNestedMarkdownInSelectedLanguage() async throws {
        let (model, assistant, _) = try fixture()
        let oldLanguage = UserDefaults.standard.string(forKey: "notes.language")
        defer { UserDefaults.standard.set(oldLanguage, forKey: "notes.language") }
        UserDefaults.standard.set("en", forKey: "notes.language")
        try model.workspace!.createAsset("Guía 1.txt", data: Data("Finite automata guide: deterministic transitions.".utf8))
        try model.createNotebookItem(kind: "cuaderno", name: "Other")
        let sibling = model.currentNotebook
        model.openNotebook("derecho")
        try model.workspace!.createAsset(sibling.rootPrefix + "/Private.txt", data: Data("Private sibling source".utf8))
        assistant.setDraft("Resume la guía 1 en resumenes", notebook: model.currentNotebook)
        var round = 0
        assistant.generate = { request, _ in
            round += 1
            XCTAssertEqual(request.language, "en")
            XCTAssertNotNil(request.catalog["Guía 1.txt"])
            XCTAssertNil(request.catalog[sibling.rootPrefix + "/Private.txt"])
            XCTAssertTrue(try request.prompt().contains("it does not determine your reply or document language"))
            XCTAssertTrue(try request.prompt().contains("automatically creates its parent folders"))
            if round == 1 { return .init(reply: "", readFiles: ["Guía 1.txt"]) }
            XCTAssertTrue(request.documents["Guía 1.txt"]?.contains("deterministic transitions") == true)
            return .init(reply: "Created the summary.", edits: [.init(path: "resumenes/summary.md", replacement: "# Summary\n\nDeterministic transitions.", create: true)])
        }
        model.submitNotebookPrompt(); await assistant.waitUntilFinished()
        XCTAssertNil(assistant.error)
        XCTAssertEqual(round, 2)
        XCTAssertTrue(try model.workspace!.readNote("resumenes/summary.md").contains("Deterministic"))
        XCTAssertEqual(try model.workspace!.readFile("Guía 1.txt"), Data("Finite automata guide: deterministic transitions.".utf8))
        let spanish = NotebookTextRequest(notebook: model.currentNotebook, profile: .init(), messages: [], currentDocument: nil, texts: [:], language: "es")
        XCTAssertTrue(try spanish.prompt().contains("no determina el idioma de tu respuesta"))
        XCTAssertThrowsError(try NotebookAssistantProtocol.changes(.init(reply: "", edits: [.init(path: "Guía 1.txt", find: "guide", replacement: "changed")]), documents: ["Guía 1.txt": "guide"]))
    }

    @MainActor func testImportedPDFBeyondAttachmentPageLimitIsReadable() throws {
        let (model, _, _) = try fixture()
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
        view.string = "Automata guide one: transition function."
        view.font = .systemFont(ofSize: 18)
        let single = try XCTUnwrap(PDFDocument(data: view.dataWithPDF(inside: view.bounds)))
        let document = PDFDocument()
        for index in 0..<30 { document.insert(try XCTUnwrap(single.page(at: 0)?.copy() as? PDFPage), at: index) }
        try model.workspace!.createAsset("Guía 1.pdf", data: try XCTUnwrap(document.dataRepresentation()))
        let content = try NotebookLibraryContext.read("Guía 1.pdf", library: NotebookFileLibrary(projects: model.projects!), notebookID: model.currentNotebook.id)
        XCTAssertTrue(content.text.contains("[Page 30]"))
        XCTAssertTrue(content.text.contains("transition function"))
        XCTAssertTrue(content.images.isEmpty)
        try model.createNotebookItem(kind: "cuaderno", name: "Other")
        let other = model.currentNotebook
        XCTAssertThrowsError(try NotebookLibraryContext.read("Guía 1.pdf", library: NotebookFileLibrary(projects: model.projects!), notebookID: other.id))
    }

    @MainActor func testBatchHeadingCleanupAcrossFilesIsOneUndoableRequest() async throws {
        let (model, assistant, _) = try fixture()
        var originals: [String: String] = [:]
        for name in ["Tema 1.md", "Tema 2.md"] {
            let original = (1...35).map { "## \($0). Heading \($0)\nBody \($0).\n" }.joined(separator: "\n")
            try model.workspace!.createNote(name, text: original); originals[name] = original
        }
        assistant.setDraft("Remove numbering from every heading in all Tema notes", notebook: model.currentNotebook)
        assistant.generate = { request, _ in
            XCTAssertTrue(try request.prompt().contains("Multiple non-overlapping edits per file") || request.prompt().contains("varios cambios no solapados por archivo"))
            let edits = originals.keys.sorted().flatMap { path in
                (1...35).map { NotebookEdit(path: path, find: "## \($0). Heading \($0)\n", replacement: "## Heading \($0)\n") }
            }
            // Exercise the provider decoder as well as atomic application (>30 edits).
            return try NotebookAssistantProtocol.decode(String(decoding: JSONEncoder().encode(NotebookAssistantResponse(reply: "Cleaned up all headings.", edits: edits)), as: UTF8.self))
        }
        model.submitNotebookPrompt(); await assistant.waitUntilFinished()
        XCTAssertNil(assistant.error)
        for path in originals.keys {
            let text = try model.workspace!.readNote(path)
            XCTAssertTrue(text.contains("## Heading 35")); XCTAssertFalse(text.contains("## 1."))
        }
        let checkpointID = try XCTUnwrap(assistant.chat(model.currentNotebook)?.messages.last?.checkpointID)
        let timeline = model.projects!.timeline(model.currentNotebook.id)
        let index = try XCTUnwrap(timeline.firstIndex(where: { $0.id == checkpointID }))
        _ = try model.projects!.restore(timeline[index - 1])
        for (path, original) in originals { XCTAssertEqual(try model.workspace!.readNote(path), original) }
        XCTAssertThrowsError(try NotebookAssistantProtocol.changes(.init(reply: "", edits: [
            .init(path: "Tema 1.md", find: "## 1. Heading 1", replacement: "A"),
            .init(path: "Tema 1.md", find: "Heading 1\n", replacement: "B")
        ]), documents: originals))
    }

    @MainActor func testShortTranslationFollowUpRepairsInvalidEditAndIsUndoable() async throws {
        let (model, assistant, _) = try fixture()
        for name in ["A", "B", "C", "D", "E"] { try model.workspace!.createNote(name + ".md", text: "# Unrelated\n") }
        let english = "# Fundamental definitions\n\nAlphabet: $\\Sigma = \\{a,b\\}$\n\nA finite set of symbols.\n"
        let spanish = "# Definiciones fundamentales\n\nAlfabeto: $\\Sigma = \\{a,b\\}$\n\nUn conjunto finito de símbolos.\n"
        assistant.setDraft("Create a guide", notebook: model.currentNotebook)
        assistant.generate = { _, _ in .init(reply: "Created the guide.", edits: [.init(path: "Z-guide.md", replacement: english, create: true)]) }
        model.submitNotebookPrompt(); await assistant.waitUntilFinished()
        XCTAssertNil(assistant.error)
        model.openNotebook("derecho")
        XCTAssertNil(model.selectedNote)
        assistant.setDraft("Make it in spanish", notebook: model.currentNotebook)
        var rounds = 0
        assistant.generate = { request, _ in
            rounds += 1
            XCTAssertEqual(request.recentlyEditedDocuments, ["Z-guide.md"])
            XCTAssertEqual(request.documents["Z-guide.md"], english)
            XCTAssertTrue(try request.prompt().contains("replaceEntireFile"))
            if rounds == 1 { return .init(reply: "Translated.", edits: [.init(path: "Z-guide.md", find: "A passage that is not in this document", replacement: spanish)]) }
            XCTAssertTrue(request.contextUpdate.contains("replaceEntireFile=true"))
            XCTAssertEqual(try model.workspace!.readNote("Z-guide.md"), english)
            return .init(reply: "Traducido al español.", edits: [.init(path: "Z-guide.md", replacement: spanish, replaceEntireFile: true)])
        }
        model.submitNotebookPrompt(); await assistant.waitUntilFinished()
        XCTAssertNil(assistant.error); XCTAssertEqual(rounds, 2)
        XCTAssertEqual(try model.workspace!.readNote("Z-guide.md"), spanish)
        let checkpoint = try XCTUnwrap(assistant.chat(model.currentNotebook)?.messages.last?.checkpointID)
        let timeline = model.projects!.timeline(model.currentNotebook.id)
        let index = try XCTUnwrap(timeline.firstIndex { $0.id == checkpoint })
        _ = try model.projects!.restore(timeline[index - 1])
        XCTAssertEqual(try model.workspace!.readNote("Z-guide.md"), english)
    }

    @MainActor func testInvalidEditRepairIsBoundedAndNeverPartiallyApplies() async throws {
        let (model, assistant, _) = try fixture()
        let original = try model.workspace!.readNote("Inicio.md")
        var rounds = 0
        assistant.setDraft("Translate this note", notebook: model.currentNotebook)
        assistant.generate = { _, _ in
            rounds += 1
            return .init(reply: "Done", edits: [
                .init(path: "Created.md", replacement: "# New\n", create: true),
                .init(path: "Inicio.md", find: "Missing passage", replacement: "Changed")
            ])
        }
        model.submitNotebookPrompt(); await assistant.waitUntilFinished()
        XCTAssertNotNil(assistant.error); XCTAssertEqual(rounds, 3)
        XCTAssertEqual(try model.workspace!.readNote("Inicio.md"), original)
        XCTAssertFalse(model.notes.contains("Created.md"))
        XCTAssertThrowsError(try NotebookAssistantProtocol.changes(.init(reply: "", edits: [.init(path: "Unread.md", replacement: "# Translation", replaceEntireFile: true)]), documents: [:]))
    }

    @MainActor func testWholeNoteReplacementRejectsInterveningTyping() async throws {
        let (model, assistant, _) = try fixture()
        let original = try model.workspace!.readNote("Inicio.md")
        assistant.setDraft("Make it in English", notebook: model.currentNotebook)
        assistant.generate = { _, _ in
            model.changeDraft("My newer draft")
            return .init(reply: "Translated", edits: [.init(path: "Inicio.md", replacement: "# Start\n\nInitial text.\n", replaceEntireFile: true)])
        }
        model.submitNotebookPrompt(); await assistant.waitUntilFinished()
        XCTAssertNotNil(assistant.error)
        XCTAssertEqual(model.draftText, "My newer draft")
        XCTAssertEqual(try model.workspace!.readNote("Inicio.md"), original)
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
    @MainActor func testQueuePersistsEditsReordersAndResumesAfterStop() async throws {
        let (model, assistant, _) = try fixture()
        let notebook = model.currentNotebook
        let gate = NotebookReplyGate()
        assistant.generate = { request, _ in .init(reply: try await gate.reply(request.messages.last!.text)) }
        assistant.setDraft("active", notebook: notebook); model.submitNotebookPrompt()
        try await gate.waitForStarted(1)
        assistant.setDraft("second", notebook: notebook); model.submitNotebookPrompt()
        assistant.setDraft("third", notebook: notebook); model.submitNotebookPrompt()
        let third = try XCTUnwrap(assistant.queued(notebook).last)
        assistant.updateQueued(notebook, id: third.id, text: "edited")
        assistant.moveQueued(notebook, id: third.id, offset: -1)
        XCTAssertEqual(assistant.queued(notebook).map(\.text), ["edited", "second"])
        assistant.stop(notebook: notebook); await assistant.waitUntilFinished()
        XCTAssertEqual(assistant.queued(notebook).count, 2)
        let reloaded = try NotebookAssistantController(store: assistant.store)
        XCTAssertEqual(reloaded.queued(notebook).map(\.text), ["edited", "second"])
        XCTAssertEqual(reloaded.runningCount, 0)
        assistant.setDraft("preserved draft", notebook: notebook)
        model.resumeNotebookQueue()
        try await gate.waitForStarted(2)
        await gate.release("edited")
        try await gate.waitForStarted(3)
        await gate.release("second")
        await assistant.waitUntilFinished()
        XCTAssertTrue(assistant.queued(notebook).isEmpty)
        XCTAssertEqual(assistant.chat(notebook)?.draft, "preserved draft")
        XCTAssertEqual(assistant.chat(notebook)?.messages.filter { $0.role == "assistant" }.map(\.text), ["Reply to edited", "Reply to second"])
    }
    @MainActor func testSteeringRestartsWithOriginalRequestAndDoesNotSaveCancelledOutput() async throws {
        let (model, assistant, _) = try fixture()
        let notebook = model.currentNotebook
        let gate = NotebookReplyGate()
        var messages: [String] = []
        assistant.generate = { request, _ in
            messages = request.messages.map(\.text)
            return .init(reply: try await gate.reply(request.messages.last!.text))
        }
        assistant.setDraft("original", notebook: notebook); model.submitNotebookPrompt()
        try await gate.waitForStarted(1)
        assistant.setDraft("use a shorter format", notebook: notebook); model.steerNotebookPrompt()
        try await gate.waitForStarted(2)
        XCTAssertEqual(messages, ["original", "use a shorter format"])
        await gate.release("use a shorter format")
        await assistant.waitUntilFinished()
        XCTAssertEqual(assistant.chat(notebook)?.messages.filter { $0.role == "assistant" }.count, 1)
        XCTAssertFalse(assistant.chat(notebook)!.messages.contains { $0.role == "error" })
        XCTAssertTrue(assistant.queued(notebook).isEmpty)
    }

    @MainActor func testNotebookPickerStartsBlankChatAndPreservesSavedChatsAndDrafts() throws {
        let (model, assistant, _) = try fixture()
        try model.createNotebookItem(kind: "cuaderno", name: "Other")
        let other = model.currentNotebook
        let previous = try assistant.newChat(other)
        assistant.setDraft("Unsent work in Other", notebook: other)
        var state = assistant.state(other)
        state.chats[0].messages = [.init(role: "assistant", text: "Existing conversation")]
        try assistant.installCopiedState(state, notebook: other)
        model.openNotebook("derecho")
        XCTAssertTrue(model.openNotebookForNewChat(other.id))
        XCTAssertEqual(model.currentNotebook.id, other.id)
        XCTAssertNotEqual(assistant.chat(other)?.id, previous)
        XCTAssertTrue(assistant.isEmptyChat(other))
        XCTAssertEqual(assistant.chat(other)?.draft, "")
        let retained = try XCTUnwrap(assistant.state(other).chats.first { $0.id == previous })
        XCTAssertEqual(retained.draft, "Unsent work in Other")
        XCTAssertEqual(retained.messages.last?.text, "Existing conversation")
    }

    @MainActor func testThreeConcurrentChatsKeepRepliesProgressAndCancellationIsolated() async throws {
        let (model, assistant, _) = try fixture()
        let firstNotebook = model.currentNotebook
        try model.createNotebookItem(kind: "cuaderno", name: "Other")
        let other = model.currentNotebook
        let otherPath = other.rootPrefix + "/Other.md"
        try model.workspace!.createNote(otherPath, text: "# Other")
        let gate = NotebookReplyGate()
        var requests: [String: NotebookTextRequest] = [:]
        assistant.generate = { request, _ in
            let prompt = request.messages.last!.text
            requests[prompt] = request
            return .init(reply: try await gate.reply(prompt))
        }
        model.openNotebook(firstNotebook.id)
        assistant.setDraft("first", notebook: firstNotebook)
        let firstID = try XCTUnwrap(assistant.chat(firstNotebook)?.id)
        model.submitNotebookPrompt()
        let secondID = try assistant.newChat(firstNotebook)
        assistant.setDraft("second", notebook: firstNotebook)
        model.submitNotebookPrompt()
        model.submitNotebookPrompt() // An active chat cannot submit twice.
        model.openNotebook(other.id)
        assistant.setDraft("third", notebook: other)
        let thirdID = try XCTUnwrap(assistant.chat(other)?.id)
        model.submitNotebookPrompt()
        try await gate.waitForStarted(3)
        XCTAssertEqual(assistant.runningCount, 3)
        XCTAssertEqual(assistant.runningCount(in: firstNotebook), 2)
        XCTAssertTrue(assistant.isRunning(other, chatID: thirdID))
        XCTAssertThrowsError(try assistant.deleteChat(firstID, notebook: firstNotebook))
        XCTAssertThrowsError(try assistant.deleteChat(secondID, notebook: firstNotebook))
        XCTAssertThrowsError(try assistant.deleteChat(thirdID, notebook: other))
        XCTAssertEqual(requests["second"]?.messages.map(\.text), ["second"])
        _ = NSApplication.shared
        let selectors = NSHostingView(rootView: VStack(spacing: 18) {
            NotebookHomePicker(model: model, assistant: assistant)
            NotebookChatPicker(notebook: firstNotebook, assistant: assistant)
            NotebookChatPicker(notebook: other, assistant: assistant)
        }.padding(20).frame(width: 500, height: 190).environment(\.colorScheme, .dark))
        selectors.frame = NSRect(x: 0, y: 0, width: 500, height: 190)
        selectors.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(selectors.bitmapImageRepForCachingDisplay(in: selectors.bounds))
        selectors.cacheDisplay(in: selectors.bounds, to: bitmap)
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("qa/concurrent-chats")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("working-selectors.png"))
        XCTAssertNil(requests["third"]?.catalog["Inicio.md"])
        XCTAssertNil(requests["first"]?.catalog[otherPath])
        assistant.selectChat(firstID, notebook: firstNotebook)
        assistant.stop(notebook: firstNotebook)
        let deadline = Date().addingTimeInterval(3)
        while assistant.isRunning(firstNotebook, chatID: firstID), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(assistant.runningCount, 2)
        XCTAssertTrue(assistant.isRunning(firstNotebook, chatID: secondID))
        XCTAssertTrue(assistant.isRunning(other, chatID: thirdID))
        XCTAssertFalse(assistant.activities(for: other).isEmpty)
        await gate.release("second")
        await gate.release("third")
        await assistant.waitUntilFinished()
        XCTAssertEqual(assistant.runningCount, 0)
        let first = try XCTUnwrap(assistant.state(firstNotebook).chats.first { $0.id == firstID })
        let second = try XCTUnwrap(assistant.state(firstNotebook).chats.first { $0.id == secondID })
        let third = try XCTUnwrap(assistant.state(other).chats.first { $0.id == thirdID })
        XCTAssertEqual(first.messages.last?.role, "error")
        XCTAssertEqual(first.messages.last?.text, "Petición cancelada.")
        XCTAssertEqual(second.messages.last?.text, "Reply to second")
        XCTAssertEqual(third.messages.last?.text, "Reply to third")
        XCTAssertNil(assistant.composerError(other))
        XCTAssertFalse(second.messages.last?.activities?.contains { $0.title.contains(otherPath) } == true)
        let reopened = try NotebookAssistantController(store: assistant.store)
        XCTAssertEqual(reopened.state(firstNotebook).chats.first { $0.id == secondID }?.messages.last?.text, "Reply to second")
        XCTAssertEqual(reopened.state(other).chats.first { $0.id == thirdID }?.messages.last?.text, "Reply to third")
    }

    @MainActor func testConcurrentEditsRejectStaleResultWithoutOverwritingFirstCompletion() async throws {
        let (model, assistant, _) = try fixture()
        let notebook = model.currentNotebook
        let gate = NotebookReplyGate()
        assistant.generate = { request, _ in
            let prompt = request.messages.last!.text
            _ = try await gate.reply(prompt)
            return .init(reply: prompt, edits: [.init(path: "Inicio.md", find: "Texto inicial.", replacement: prompt)])
        }
        assistant.setDraft("first edit", notebook: notebook)
        let firstID = try XCTUnwrap(assistant.chat(notebook)?.id)
        model.submitNotebookPrompt()
        let secondID = try assistant.newChat(notebook)
        assistant.setDraft("second edit", notebook: notebook)
        model.submitNotebookPrompt()
        try await gate.waitForStarted(2)
        await gate.release("first edit")
        let deadline = Date().addingTimeInterval(3)
        while assistant.isRunning(notebook, chatID: firstID), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(assistant.isRunning(notebook, chatID: firstID))
        await gate.release("second edit")
        await assistant.waitUntilFinished()
        XCTAssertTrue(try model.workspace!.readNote("Inicio.md").contains("first edit"))
        XCTAssertFalse(try model.workspace!.readNote("Inicio.md").contains("second edit"))
        XCTAssertEqual(assistant.state(notebook).chats.first { $0.id == secondID }?.messages.last?.role, "error")
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
    @MainActor func testRequestsAdditionalFilesAndPreservesProviderCitations() async throws {
        let (model, assistant, _) = try fixture()
        for name in ["A", "B", "C", "D", "Z"] { try model.workspace?.createNote(name + ".md", text: "# \(name)\n") }
        assistant.setDraft("Añade Art. 13 del Estatuto de los Trabajadores", notebook: model.currentNotebook)
        var round = 0
        assistant.generate = { request, _ in
            round += 1
            if round == 1 { return .init(reply: "", readFiles: ["Z.md"]) }
            XCTAssertEqual(request.documents["Z.md"], "# Z\n")
            return .init(reply: "Added", edits: [.init(path: "Z.md", find: "# Z\n", replacement: "# Z\n\nProvider text with source citation")])
        }
        model.submitNotebookPrompt(); await assistant.waitUntilFinished()
        XCTAssertNil(assistant.error); XCTAssertEqual(round, 2)
        let activities = try XCTUnwrap(assistant.chat(model.currentNotebook)?.messages.last?.activities)
        XCTAssertTrue(activities.contains { $0.title.contains("Z.md") })
        XCTAssertTrue(activities.last?.title.contains("1 archivo") == true)
        XCTAssertNil(assistant.runningChatID)
        XCTAssertTrue(try model.workspace!.readNote("Z.md").contains("Provider text with source citation"))
    }
    @MainActor func testAmbiguityProviderFailureAndCancellationLeaveNotesUntouched() async throws {
        let (model, assistant, _) = try fixture()
        let initial = try model.workspace!.readNote("Inicio.md")
        assistant.setDraft("Art. 13", notebook: model.currentNotebook)
        assistant.generate = { _, _ in .init(reply: "¿De qué ley?") }
        model.submitNotebookPrompt(); await assistant.waitUntilFinished()
        XCTAssertEqual(assistant.chat(model.currentNotebook)?.messages.last?.text, "¿De qué ley?")
        assistant.setDraft("Art. 13 del Estatuto", notebook: model.currentNotebook)
        assistant.generate = { _, _ in throw MediaError.invalid("Offline") }
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
    @MainActor func testActivityAndComposerErrorRenderInHomeAndDocument() async throws {
        let (model, assistant, _) = try fixture()
        let media = try XCTUnwrap(model.media)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "activity-render-" + UUID().uuidString))
        defaults.set("en", forKey: "notes.language")
        defaults.set(NotebookAccent.encode(.purple), forKey: "notes.accent")
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("qa/activity-status")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for scenario in ["home-processing", "document-recording", "hidden-composer-recording", "document-error", "document-error-narrow"] {
            media.isRecording = scenario.contains("recording")
            media.busy = scenario == "home-processing"
            model.hideStudyComposer = scenario == "hidden-composer-recording"
            if scenario.hasPrefix("home") { model.openNotebook("derecho") }
            else { model.openNote("Inicio.md"); model.layout = "preview" }
            assistant.error = scenario.hasPrefix("document-error") ? "Antigravity closed the connection or timed out. Retry explicitly." : nil
            if scenario == "document-error-narrow" { assistant.error = Array(repeating: assistant.error!, count: 3).joined(separator: " ") }
            let size = NSSize(width: scenario.hasSuffix("narrow") ? 600 : 1280, height: 820)
            let host = NSHostingView(rootView: WorkbenchView(model: model).defaultAppStorage(defaults).environment(\.colorScheme, .dark))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host; host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(200)); host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(scenario + ".png"))
            window.close()
        }
        media.isRecording = false; media.busy = false
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
    @MainActor func testFolderDeletionArchivesOtherAssetsAndRejectsNotebookRoots() throws {
        let (model, _, root) = try fixture()
        try model.createNotebookItem(kind: "carpeta", name: "Assets")
        try Data("Keep".utf8).write(to: root.appendingPathComponent("copied-course/Assets/file.txt"))
        model.deleteItem("Assets", folder: true)
        XCTAssertNil(model.errorText)
        XCTAssertEqual(model.trash.count, 1)
        model.restoreTrash(try XCTUnwrap(model.trash.first))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("copied-course/Assets/file.txt")), Data("Keep".utf8))
        try model.createNotebookItem(kind: "cuaderno", name: "Other")
        model.deleteItem("Cuadernos", folder: true)
        XCTAssertNotNil(model.errorText)
        XCTAssertEqual(model.activeNotebooks.count, 2)
    }

}


private actor NotebookReplyGate {
    private var started: Set<String> = []
    private var released: Set<String> = []
    func reply(_ prompt: String) async throws -> String {
        started.insert(prompt)
        while !released.contains(prompt) { try await Task.sleep(for: .milliseconds(10)) }
        try Task.checkCancellation()
        return "Reply to " + prompt
    }
    func release(_ prompt: String) { released.insert(prompt) }
    func waitForStarted(_ count: Int) async throws {
        let deadline = Date().addingTimeInterval(3)
        while started.count < count {
            guard Date() < deadline else { throw MediaError.invalid("Concurrent requests did not start") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
