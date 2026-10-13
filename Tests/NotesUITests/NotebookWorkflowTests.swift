import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import LectureCore
@testable import Notes

final class NotebookWorkflowTests: XCTestCase {
    @MainActor func testFloatingChatWelcomeAndHistoryLayouts() async throws {
        let (model, root) = try environment()
        defer { model.media?.shutdown(); model.ai?.stop(); try? FileManager.default.removeItem(at: root) }
        let assistant = try XCTUnwrap(model.assistant)
        let notebook = model.currentNotebook
        assistant.setDraft("Pending message stays unchanged", notebook: notebook)
        let chatID = try XCTUnwrap(assistant.chat(notebook)?.id)
        let output = root.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("qa/floating-chat")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let suite = "floating-chat-qa-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("en", forKey: "notes.language")
        for history in [false, true] {
            if history {
                var state = assistant.state(notebook)
                let index = try XCTUnwrap(state.chats.firstIndex { $0.id == chatID })
                state.chats[index].title = "Explain step by step, ready to hand in an exercise"
                state.chats[index].messages = [.init(role: "user", text: "Explain this document"), .init(role: "assistant", text: "**Pipeline summary**\n\nThe existing conversation remains available here.")]
                try assistant.installCopiedState(state, notebook: notebook)
            }
            for width: CGFloat in [420, 740] {
                for dark in [false, true] {
                    let host = NSHostingView(rootView: NotebookFloatingChat(model: model, assistant: assistant, onClose: {})
                        .frame(width: width).frame(maxHeight: .infinity, alignment: .top)
                        .defaultAppStorage(defaults).environment(\.colorScheme, dark ? .dark : .light))
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 320), styleMask: [.titled], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    window.contentView = host
                    host.frame = NSRect(x: 0, y: 0, width: width, height: 320)
                    host.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(200))
                    host.layoutSubtreeIfNeeded()
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let filename = "\(history ? "history" : "welcome")-\(Int(width))-\(dark ? "dark" : "light").png"
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(filename))
                    window.close()
                }
            }
        }
        XCTAssertEqual(assistant.chat(notebook)?.id, chatID)
        XCTAssertEqual(assistant.chat(notebook)?.draft, "Pending message stays unchanged")
    }
    @MainActor func testExpandFloatingChatPreservesConversationAndDocumentDraft() throws {
        let (model, root) = try environment()
        defer { model.media?.shutdown(); model.ai?.stop(); try? FileManager.default.removeItem(at: root) }
        model.openNote("Inicio.md")
        let notebook = model.currentNotebook
        let assistant = try XCTUnwrap(model.assistant)
        assistant.setDraft("Continue this conversation", notebook: notebook)
        let chatID = try XCTUnwrap(assistant.chat(notebook)?.id)
        var state = assistant.state(notebook)
        let chatIndex = try XCTUnwrap(state.chats.firstIndex { $0.id == chatID })
        state.chats[chatIndex].messages = [.init(role: "user", text: "Explain this document"), .init(role: "assistant", text: "Existing explanation")]
        try assistant.installCopiedState(state, notebook: notebook)
        model.changeDraft("# Updated document\n\nUnsaved text.")
        model.documentChatVisible = true
        model.expandNotebookChat()
        XCTAssertNil(model.selectedLibraryPath)
        XCTAssertEqual(model.currentNotebook.id, notebook.id)
        XCTAssertEqual(assistant.chat(notebook)?.id, chatID)
        XCTAssertEqual(assistant.chat(notebook)?.draft, "Continue this conversation")
        XCTAssertEqual(assistant.chat(notebook)?.messages.map(\.text), ["Explain this document", "Existing explanation"])
        XCTAssertTrue(model.chatHistoryVisible)
        XCTAssertFalse(model.documentChatVisible)
        XCTAssertFalse(model.showsDocumentComposer)
        XCTAssertEqual(try model.workspace!.readNote("Inicio.md"), "# Updated document\n\nUnsaved text.")
        model.openNote("Inicio.md")
        XCTAssertEqual(model.draftText, "# Updated document\n\nUnsaved text.")
    }
    @MainActor private func environment() throws -> (Workbench, URL) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".test-workspaces/Notebook-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("copied-course"), withIntermediateDirectories: true)
        try Data("# Inicio\n\nNota inventada.\n".utf8).write(to: root.appendingPathComponent("copied-course/Inicio.md"))
        try JSONSerialization.data(withJSONObject: ["originalRoot": root.appendingPathComponent("original").path]).write(to: root.appendingPathComponent("original-hashes.json"))
        let model = Workbench(workspaceRoot: root)
        XCTAssertNil(model.errorText)
        return (model, root)
    }

    @MainActor func testNotebookRenamePersistsIdentityAndContents() throws {
        let (model, root) = try environment()
        defer { model.media?.shutdown(); model.ai?.stop(); try? FileManager.default.removeItem(at: root) }
        try model.createNotebookItem(kind: "cuaderno", name: "Original")
        let notebook = model.currentNotebook
        try model.createNotebookItem(kind: "nota", name: "Kept", notebookID: notebook.id, folder: notebook.rootPrefix)
        try model.renameNotebook(notebook.id, name: "Renamed notebook")
        XCTAssertEqual(model.currentNotebook.name, "Renamed notebook")
        XCTAssertEqual(model.currentNotebook.id, notebook.id)
        XCTAssertEqual(try model.workspace!.readNote(notebook.rootPrefix + "/Kept.md"), "# Kept\n\n")
        let saved = try JSONDecoder().decode([Notebook].self, from: model.workspace!.readStorage("notebooks.json"))
        XCTAssertEqual(saved.first { $0.id == notebook.id }?.name, "Renamed notebook")
        XCTAssertThrowsError(try model.renameNotebook(notebook.id, name: model.notebooks.first { $0.id != notebook.id }!.name))
    }

    @MainActor func testDocumentRenamePreservesExtensionsContentsAndSelection() throws {
        let (model, root) = try environment()
        defer { model.media?.shutdown(); model.ai?.stop(); try? FileManager.default.removeItem(at: root) }
        let workspace = try XCTUnwrap(model.workspace)
        model.openNote("Inicio.md")
        model.drafts["Inicio.md"] = "# Updated draft"
        try model.renameLibraryFile("Inicio.md", name: "Renamed")
        XCTAssertEqual(model.selectedNote, "Renamed.md")
        XCTAssertEqual(try workspace.readNote("Renamed.md"), "# Updated draft")
        XCTAssertFalse(model.notes.contains("Inicio.md"))
        try workspace.createAsset("Source.pdf", data: Data("Original bytes".utf8))
        model.refreshProjectFiles(["Source.pdf"])
        model.openLibraryFile("Source.pdf")
        try model.renameLibraryFile("Source.pdf", name: "Reference.pdf")
        XCTAssertEqual(model.selectedFile, "Reference.pdf")
        XCTAssertEqual(try workspace.readFile("Reference.pdf"), Data("Original bytes".utf8))
        try workspace.createAsset("Taken.pdf", data: Data("Other bytes".utf8))
        XCTAssertThrowsError(try model.renameLibraryFile("Reference.pdf", name: "Taken"))
        XCTAssertEqual(try workspace.readFile("Taken.pdf"), Data("Other bytes".utf8))
    }

    @MainActor func testFolderRenamePreservesNestedFilesDraftAndSelection() throws {
        let (model, root) = try environment()
        defer { model.media?.shutdown(); model.ai?.stop(); try? FileManager.default.removeItem(at: root) }
        let workspace = try XCTUnwrap(model.workspace)
        try workspace.createFolder("Unit/Nested/Empty")
        try workspace.createNote("Unit/Nested/Note.md", text: "# Original")
        try workspace.createAsset("Unit/Nested/Source.pdf", data: Data("PDF fixture bytes".utf8))
        model.refreshProjectFiles(["Unit/Nested/Note.md", "Unit/Nested/Source.pdf"])
        model.openNote("Unit/Nested/Note.md")
        model.drafts["Unit/Nested/Note.md"] = "# Unsaved edit"
        try model.renameLibraryFolder("Unit", name: "Renamed")
        XCTAssertEqual(try workspace.readNote("Renamed/Nested/Note.md"), "# Unsaved edit")
        XCTAssertEqual(try workspace.readFile("Renamed/Nested/Source.pdf"), Data("PDF fixture bytes".utf8))
        XCTAssertTrue(model.folders.contains("Renamed/Nested/Empty"))
        XCTAssertFalse(model.folders.contains("Unit"))
        XCTAssertEqual(model.selectedNote, "Renamed/Nested/Note.md")
        XCTAssertNil(model.drafts["Unit/Nested/Note.md"])
        try workspace.createFolder("Taken")
        XCTAssertThrowsError(try model.renameLibraryFolder("Renamed", name: "Taken"))
        XCTAssertThrowsError(try model.renameLibraryFolder("Renamed", name: "../Escape"))
        XCTAssertEqual(try workspace.readNote("Renamed/Nested/Note.md"), "# Unsaved edit")
    }

    @MainActor func testCreationRefreshDiscoversEmptyAndNestedFoldersAndCreatesInSelectedNotebook() throws {
        let (model, root) = try environment()
        defer { model.media?.shutdown(); model.ai?.stop(); try? FileManager.default.removeItem(at: root) }
        try model.createNotebookItem(kind: "cuaderno", name: "Second")
        let second = model.currentNotebook
        let nested = second.rootPrefix + "/Unit/Nested/Empty"
        try model.workspace!.createFolder(nested)
        XCTAssertFalse(model.folders.contains(nested))
        try model.refreshCreationLocations()
        XCTAssertTrue(model.folderNames(in: second).contains(nested))
        try model.createNotebookItem(kind: "nota", name: "New note", notebookID: second.id, folder: nested)
        XCTAssertEqual(model.selectedNote, nested + "/New note.md")
        XCTAssertTrue(model.notes.contains(nested + "/New note.md"))
        XCTAssertFalse(model.folderNames(in: .copiedCourse).contains(nested))
    }

    @MainActor func testNotebookOrderingPersistenceAndModificationDates() throws {
        let (model, root) = try environment()
        defer { model.media?.shutdown(); model.ai?.stop(); try? FileManager.default.removeItem(at: root) }
        try model.createNotebookItem(kind: "cuaderno", name: "Zeta")
        let zeta = model.currentNotebook
        try model.createNotebookItem(kind: "cuaderno", name: "Álgebra")
        let algebra = model.currentNotebook
        model.setNotebookSort(.alphabetical)
        XCTAssertEqual(model.activeNotebooks.map(\.name), ["Álgebra", "Derecho del Trabajo", "Zeta"])
        XCTAssertTrue(model.reorderNotebook(zeta.id, relativeTo: algebra.id))
        XCTAssertEqual(model.notebookOrdering.sort, .manual)
        XCTAssertEqual(model.activeNotebooks.map(\.id), [zeta.id, algebra.id, "derecho"])
        XCTAssertTrue(model.reorderNotebook(zeta.id, relativeTo: "derecho", after: true))
        XCTAssertEqual(model.activeNotebooks.map(\.id), [algebra.id, "derecho", zeta.id])
        XCTAssertFalse(model.reorderNotebook("missing", relativeTo: algebra.id))
        let workspace = try XCTUnwrap(model.workspace)
        try workspace.createNote(zeta.rootPrefix + "/Lecture.md", text: "# Lecture")
        try workspace.createNote(algebra.rootPrefix + "/Lecture.md", text: "# Lecture")
        model.libraryFiles = try workspace.fileNames()
        let newest = Date().addingTimeInterval(120)
        try FileManager.default.setAttributes([.modificationDate: newest], ofItemAtPath: workspace.fileURL(zeta.rootPrefix + "/Lecture.md").path)
        model.setNotebookSort(.modified)
        XCTAssertEqual(model.activeNotebooks.first?.id, zeta.id)
        try FileManager.default.setAttributes([.modificationDate: newest.addingTimeInterval(60)], ofItemAtPath: workspace.fileURL(algebra.rootPrefix + "/Lecture.md").path)
        XCTAssertEqual(model.activeNotebooks.first?.id, algebra.id)
        let reopened = Workbench(workspaceRoot: root)
        defer { reopened.media?.shutdown(); reopened.ai?.stop() }
        XCTAssertNil(reopened.errorText)
        XCTAssertEqual(reopened.notebookOrdering.sort, .modified)
        XCTAssertEqual(reopened.activeNotebooks.first?.id, algebra.id)
        reopened.setNotebookSort(.manual)
        XCTAssertEqual(reopened.activeNotebooks.map(\.id), [algebra.id, "derecho", zeta.id])
        XCTAssertEqual(try workspace.readNote(zeta.rootPrefix + "/Lecture.md"), "# Lecture")
    }

    @MainActor func testOpeningWorkspaceDoesNotCreateSyntheticSession() throws {
        let (model, root) = try environment()
        defer { model.media?.shutdown(); model.ai?.stop(); try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(model.sessions.isEmpty)
        XCTAssertNil(model.document)
        XCTAssertTrue(try XCTUnwrap(model.workspace).loadSessions().isEmpty)
        XCTAssertEqual(model.selectedNote, "Inicio.md")
        model.changeDraft("# Inicio\n\nEdición real.\n")
        model.saveDraft()
        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(try XCTUnwrap(model.workspace).readNote("Inicio.md"), "# Inicio\n\nEdición real.\n")
        XCTAssertFalse(try XCTUnwrap(model.editor).history.isEmpty)
    }

    @MainActor func testProviderPreferencesDraftValidationSaveDiscardAndFailure() async throws {
        let (model, root) = try environment()
        defer { model.media?.shutdown(); model.ai?.stop(); try? FileManager.default.removeItem(at: root) }
        let ai = try XCTUnwrap(model.ai)
        let preferences = ProviderPreferencesModel(ai: ai)
        preferences.draft.selectedProvider = .codexCLI
        preferences.draft.codexCLI.model = "example-model"
        XCTAssertEqual(ai.providerSettings.selectedProvider, .openCode)
        preferences.draft.codexCLI.executablePath = "relative/path"
        preferences.save()
        XCTAssertNotNil(preferences.error)
        XCTAssertEqual(ai.providerSettings.selectedProvider, .openCode)
        preferences.draft.codexCLI.executablePath = "/missing/codex"
        preferences.save()
        XCTAssertNil(preferences.error)
        XCTAssertFalse(preferences.hasChanges)
        let reopened = ProviderPreferencesModel(ai: ai)
        XCTAssertEqual(reopened.draft.codexCLI.model, "example-model")
        reopened.draft.codexCLI.model = "changed-model"
        reopened.discard()
        XCTAssertEqual(reopened.draft.codexCLI.model, "example-model")
        await reopened.checkInstallation()
        XCTAssertNotNil(reopened.error)
        XCTAssertNil(reopened.diagnostic)
        XCTAssertFalse(reopened.checking)
        XCTAssertEqual(try AIProviderSettings.load(in: XCTUnwrap(model.workspace)).codexCLI.executablePath, "/missing/codex")
        XCTAssertTrue(ai.outbox.batches.isEmpty)
        await preferences.testConnection()
        XCTAssertNotNil(preferences.connectionError)
        XCTAssertNil(preferences.connectionResult)
        XCTAssertFalse(preferences.testingConnection)
        XCTAssertTrue(preferences.connectionResultIsCurrent)
        preferences.selectModel("different-model")
        XCTAssertFalse(preferences.connectionResultIsCurrent)
        XCTAssertTrue(ai.outbox.batches.isEmpty)
    }

    @MainActor func testModelSelectionFavoritesVisibilityAndCustomModelsSurviveReload() throws {
        let (model, root) = try environment()
        defer { model.media?.shutdown(); model.ai?.stop(); try? FileManager.default.removeItem(at: root) }
        let ai = try XCTUnwrap(model.ai)
        let preferences = ProviderPreferencesModel(ai: ai)
        preferences.draft.selectedProvider = .codexCLI
        preferences.addCustomModel("example-a")
        preferences.addCustomModel("example-b")
        preferences.addCustomModel("example-c")
        preferences.move("example-b", offset: -1)
        XCTAssertEqual(preferences.models.first?.id, "example-b")
        preferences.favorite("example-c")
        XCTAssertEqual(preferences.models.first?.id, "example-c")
        preferences.selectModel("example-b")
        preferences.hide("example-a")
        preferences.draft.selected.reasoningEffort = "low"
        preferences.draft.selected.fastMode = true
        preferences.save()
        XCTAssertNil(preferences.error)
        let saved = try AIProviderSettings.load(in: XCTUnwrap(model.workspace))
        XCTAssertEqual(saved.selected.model, "example-b")
        XCTAssertEqual(saved.selected.reasoningEffort, "low")
        XCTAssertEqual(saved.selected.fastMode, true)
        preferences.favorite("other-provider-model", provider: .antigravity)
        XCTAssertTrue(preferences.draft.modelPreferences?["antigravity"]?.favorites.contains("other-provider-model") == true)
        XCTAssertEqual(preferences.draft.selectedProvider, .codexCLI)
        preferences.draft.editAutonomy = .additions
        preferences.save()
        XCTAssertEqual(try AIProviderSettings.load(in: XCTUnwrap(model.workspace)).editAutonomy, .additions)
        XCTAssertEqual(saved.modelPreferences?["codexCLI"]?.favorites, ["example-c"])
        XCTAssertEqual(saved.modelPreferences?["codexCLI"]?.hidden, ["example-a"])
        XCTAssertEqual(saved.modelPreferences?["codexCLI"]?.custom.count, 3)
        preferences.removeCustomModel("example-b")
        XCTAssertEqual(preferences.draft.selected.model, "default")
        preferences.discard()
        XCTAssertEqual(preferences.draft.selected.model, "example-b")
        preferences.addCustomModel("bad --flag")
        XCTAssertNotNil(preferences.error)
        XCTAssertEqual(preferences.models.count, 3)
    }

    @MainActor func testProviderSettingsReloadConsentAndQueuedSnapshotIsolation() throws {
        let (model, root) = try environment()
        defer { model.media?.shutdown(); model.ai?.stop(); try? FileManager.default.removeItem(at: root) }
        model.createAIDemo()
        let ai = try XCTUnwrap(model.ai)
        let media = try XCTUnwrap(model.media?.selected)
        var settings = ai.providerSettings
        settings.selectedProvider = .codexCLI
        settings.codexCLI.accountSendingAllowed = false
        try ai.saveProviderSettings(settings)
        ai.send(media: media, ids: Set(media.transcript.map(\.id)))
        XCTAssertNotNil(ai.error)
        XCTAssertTrue(ai.outbox.batches.isEmpty)
        XCTAssertFalse(ai.running)
        settings.codexCLI.accountSendingAllowed = true
        settings.codexCLI.model = "example-model"
        try ai.saveProviderSettings(settings)
        var pending = try ai.outbox.enqueue(media: media, selected: media.transcript)
        pending.providerConfiguration = settings.selected
        pending.model = settings.selected.model
        try ai.outbox.replace(pending)
        settings.selectedProvider = .openCode
        try ai.saveProviderSettings(settings)
        let restored = Workbench(workspaceRoot: root)
        defer { restored.media?.shutdown(); restored.ai?.stop() }
        XCTAssertNil(restored.errorText)
        XCTAssertEqual(restored.ai?.providerSettings.selectedProvider, .openCode)
        XCTAssertEqual(restored.ai?.providerSettings.codexCLI.model, "example-model")
        XCTAssertEqual(restored.ai?.batches.first?.providerConfiguration?.provider, .codexCLI)
        XCTAssertEqual(restored.ai?.batches.first?.model, "example-model")
        ai.running = true
        XCTAssertThrowsError(try ai.saveProviderSettings(settings))
        ai.running = false
    }

    @MainActor func testNewNoteDestinationIsExplicitAndConfinedToChosenNotebook() throws {
        let (model, root) = try environment()
        defer { model.media?.shutdown(); model.ai?.stop(); try? FileManager.default.removeItem(at: root) }
        let first = model.currentNotebook
        try model.createNotebookItem(kind: "cuaderno", name: "Algorithms")
        let target = model.currentNotebook
        try model.createNotebookItem(kind: "carpeta", name: "Unit/Exercises")
        model.openNotebook(first.id)
        let folder = target.rootPrefix + "/Unit/Exercises"
        try model.createNotebookItem(kind: "nota", name: "Transitions", notebookID: target.id, folder: folder)
        XCTAssertEqual(model.selectedNotebookID, target.id)
        XCTAssertEqual(model.selectedNote, folder + "/Transitions.md")
        XCTAssertEqual(try model.workspace!.readNote(folder + "/Transitions.md"), "# Transitions\n\n")
        let selected = model.selectedNote
        XCTAssertThrowsError(try model.createNotebookItem(kind: "nota", name: "Transitions", notebookID: target.id, folder: folder))
        XCTAssertThrowsError(try model.createNotebookItem(kind: "nota", name: "Outside", notebookID: first.id, folder: folder))
        XCTAssertThrowsError(try model.createNotebookItem(kind: "nota", name: "../Outside", notebookID: target.id, folder: folder))
        XCTAssertThrowsError(try model.createNotebookItem(kind: "nota", name: "Missing", notebookID: "missing", folder: ""))
        XCTAssertEqual(model.selectedNote, selected)
        try model.createNotebookItem(kind: "nota", name: "Root note", notebookID: first.id, folder: first.rootPrefix)
        XCTAssertEqual(model.selectedNote, "Root note.md")
        XCTAssertEqual(model.selectedNotebookID, first.id)
        XCTAssertFalse(try model.workspace!.noteNames().contains("Outside.md"))
    }

    @MainActor func testNotebookFolderDraftSwitchSaveAndReload() throws {
        let (model, root) = try environment()
        defer { model.media?.shutdown(); model.ai?.stop(); try? FileManager.default.removeItem(at: root) }
        try model.createNotebookItem(kind: "cuaderno", name: "Prueba café 👩🏽‍💻")
        let notebookID = model.selectedNotebookID
        XCTAssertNil(model.selectedNote)
        try model.createNotebookItem(kind: "nota", name: "Inicio")
        let startNote = try XCTUnwrap(model.selectedNote)
        try model.createNotebookItem(kind: "carpeta", name: "Unidad 1")
        try model.createNotebookItem(kind: "nota", name: "Unidad 1/Correcciones")
        let note = try XCTUnwrap(model.selectedNote)
        let text = "# Correcciones\n\n**Acción** y niño 👩🏽‍💻.\n\n- Dos pasos, no tres.\n\n```swift\nlet café = 2\n```\n"
        model.changeDraft(text)
        XCTAssertTrue(model.isDirty)
        model.openNote(startNote)
        model.openNote(note)
        XCTAssertEqual(model.draftText, text)
        model.saveDraft()
        XCTAssertNil(model.errorText)
        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(try model.workspace?.readNote(note), text)
        XCTAssertThrowsError(try model.createNotebookItem(kind: "cuaderno", name: "Prueba café 👩🏽‍💻"))
        XCTAssertThrowsError(try model.createNotebookItem(kind: "nota", name: "Unidad 1/Correcciones"))
        XCTAssertEqual(try model.workspace?.readNote(note), text)
        let restored = Workbench(workspaceRoot: root)
        defer { restored.media?.shutdown(); restored.ai?.stop() }
        restored.openNote(note)
        XCTAssertNil(restored.errorText)
        XCTAssertEqual(restored.selectedNotebookID, notebookID)
        XCTAssertEqual(restored.draftText, text)
        XCTAssertFalse(restored.isDirty)
    }

    @MainActor func testGeneratedProposalReviewDirtyGuardApplyUndoAndReload() throws {
        let (model, root) = try environment()
        defer { model.media?.shutdown(); model.ai?.stop(); try? FileManager.default.removeItem(at: root) }
        model.createAIDemo()
        XCTAssertNil(model.errorText)
        let media = try XCTUnwrap(model.media?.selected)
        let ai = try XCTUnwrap(model.ai)
        var batch = try ai.outbox.enqueue(media: media, selected: [media.transcript[0]])
        let response: [String: Any] = ["version": 1, "batch_id": batch.id, "decisions": [["source_ids": ["s1"], "action": "correct", "text": "El concepto A utiliza dos pasos.", "reason": "Corrección explícita inventada.", "target_quote": "El concepto A utiliza tres pasos."]]]
        batch.decisions = try OpenRouterHarness.decodeResponse(String(decoding: JSONSerialization.data(withJSONObject: response), as: UTF8.self), for: batch)
        batch.stage = .ready
        try ai.outbox.replace(batch)
        ai.refresh()
        let proposal = try XCTUnwrap(batch.decisions.first)
        XCTAssertEqual(try model.workspace?.readNote(media.targetNote), SyntheticAIFixture.note)
        model.changeDraft(SyntheticAIFixture.note + "\nBorrador sin guardar.\n")
        model.applyAI(batch: batch, proposal: proposal, text: proposal.text, quote: proposal.targetQuote)
        XCTAssertNotNil(model.errorText)
        XCTAssertTrue(model.draftText.contains("Borrador sin guardar"))
        XCTAssertEqual(try model.workspace?.readNote(media.targetNote), SyntheticAIFixture.note)
        model.changeDraft(SyntheticAIFixture.note)
        model.errorText = nil
        model.applyAI(batch: batch, proposal: proposal, text: proposal.text, quote: proposal.targetQuote)
        XCTAssertNil(model.errorText)
        XCTAssertTrue(model.draftText.contains("dos pasos"))
        XCTAssertFalse(model.isDirty)
        let restored = Workbench(workspaceRoot: root)
        defer { restored.media?.shutdown(); restored.ai?.stop() }
        restored.openNote(media.targetNote)
        XCTAssertTrue(restored.draftText.contains("dos pasos"))
        XCTAssertNotNil(restored.ai?.batches.first?.decisions.first?.resolution)
        restored.undoEditor()
        XCTAssertNil(restored.errorText)
        XCTAssertEqual(restored.draftText, SyntheticAIFixture.note)
        XCTAssertEqual(try restored.workspace?.readNote(media.targetNote), SyntheticAIFixture.note)
        XCTAssertNil(restored.ai?.batches.first?.decisions.first?.resolution)
    }
}
