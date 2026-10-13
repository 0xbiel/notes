import XCTest
import AppKit
import PDFKit
import SwiftUI
import LectureCore
@testable import Notes

final class NotebookLibraryTests: XCTestCase {
    @MainActor private func fixture() throws -> (Workbench, URL, NSPasteboard) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".test-workspaces/Library-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("copied-course"), withIntermediateDirectories: true)
        try Data("# Original\n".utf8).write(to: root.appendingPathComponent("copied-course/Inicio.md"))
        try JSONSerialization.data(withJSONObject: ["originalRoot": root.appendingPathComponent("original").path]).write(to: root.appendingPathComponent("original-hashes.json"))
        let model = Workbench(workspaceRoot: root)
        XCTAssertNil(model.errorText)
        let clipboard = NSPasteboard(name: .init("palladium-test-" + UUID().uuidString))
        addTeardownBlock { @MainActor in
            model.assistant?.stop(); model.ai?.stop(); model.media?.shutdown()
            model.autosaveTasks.values.forEach { $0.cancel() }
            clipboard.clearContents(); try? FileManager.default.removeItem(at: root)
        }
        return (model, root, clipboard)
    }

    @MainActor func testSidebarRemembersOpenNotebooksAndFoldersAcrossRelaunch() throws {
        let (model, root, _) = try fixture()
        let key = "notes.sidebarExpanded"
        addTeardownBlock {
            var saved = UserDefaults.standard.dictionary(forKey: key) ?? [:]
            saved[root.path] = nil
            UserDefaults.standard.set(saved, forKey: key)
        }
        model.sidebarExpanded = [.notebook("a"), .folder("Tema 1/Apuntes")]
        // Leaving for Preferences rebuilds the sidebar; the state lives in the workbench.
        XCTAssertTrue(model.sidebarExpanded.contains(.folder("Tema 1/Apuntes")))
        let relaunched = Workbench(workspaceRoot: root)
        addTeardownBlock { @MainActor in relaunched.assistant?.stop(); relaunched.ai?.stop(); relaunched.media?.shutdown() }
        XCTAssertEqual(relaunched.sidebarExpanded, [.notebook("a"), .folder("Tema 1/Apuntes")])
        model.sidebarExpanded.remove(.notebook("a"))
        XCTAssertEqual(Workbench(workspaceRoot: root).sidebarExpanded, [.folder("Tema 1/Apuntes")])
    }
    @MainActor func testLegacyGeneratedImagesMigrateWithoutTouchingUserAssets() throws {
        let (model, _, _) = try fixture()
        let path = "assets/image-" + UUID().uuidString.lowercased() + ".gif"
        let gif = Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")!
        try model.workspace!.createAsset(path, data: gif)
        try model.workspace!.createAsset("assets/user-picture.gif", data: gif)
        try model.workspace!.createNote("Picture.md", text: "![Picture](" + path + ")")
        model.refreshProjectFiles([]); model.openNote("Picture.md"); model.saveDraft()
        let reference = try XCTUnwrap(NotebookImageStorage.references(model.draftText, note: "Picture.md", workspace: model.workspace!).first)
        XCTAssertTrue(reference.path.hasPrefix(".palladium-images/"))
        XCTAssertEqual(try model.workspace!.readFile(reference.path), gif)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try model.workspace!.fileURL(path).path))
        XCTAssertEqual(try model.workspace!.readFile("assets/user-picture.gif"), gif)
        model.changeDraft("Removed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: try model.workspace!.fileURL(reference.path).path))
        model.changeDraft("![Picture](" + reference.path + ")")
        XCTAssertEqual(try model.workspace!.readFile(reference.path), gif)
    }

    @MainActor func testMultipleSelectionMovePreservesDraftsImagesAndNestedFolders() throws {
        let (model, root, _) = try fixture()
        let workspace = model.workspace!
        let imagePath = ".palladium-images/image-" + UUID().uuidString.lowercased() + ".gif"
        let gif = Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")!
        try workspace.createAsset(imagePath, data: gif)
        try workspace.createFolder("Lessons/Empty")
        try workspace.createNote("Lessons/Topic.md", text: "![Picture](../" + imagePath + ")")
        try workspace.createAsset("manual.pdf", data: Data([1, 2, 3]))
        model.refreshProjectFiles([])
        model.openNote("Inicio.md"); model.changeDraft("Unsaved draft")
        try model.createNotebookItem(kind: "cuaderno", name: "Target")
        let target = model.currentNotebook
        try workspace.createNote(target.rootPrefix + "/Inicio.md", text: "Existing")
        model.setLibrarySelections([.folder("Lessons"), .note("Lessons/Topic.md"), .note("Inicio.md"), .note("manual.pdf")])
        XCTAssertEqual(model.librarySelections.count, 4)
        model.moveLibraryItems(model.librarySelections, into: target.rootPrefix, notebookID: target.id)
        XCTAssertNil(model.errorText)
        XCTAssertEqual(try workspace.readNote(target.rootPrefix + "/Inicio.md"), "Existing")
        XCTAssertEqual(try workspace.readNote(target.rootPrefix + "/Inicio copy.md"), "Unsaved draft")
        XCTAssertEqual(try workspace.readFile(target.rootPrefix + "/manual.pdf"), Data([1, 2, 3]))
        XCTAssertTrue(model.folders.contains(target.rootPrefix + "/Lessons/Empty"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("copied-course/Lessons").path))
        let movedNote = target.rootPrefix + "/Lessons/Topic.md"
        let text = try workspace.readNote(movedNote)
        let reference = try XCTUnwrap(NotebookImageStorage.references(text, note: movedNote, workspace: workspace).first)
        XCTAssertTrue(reference.path.hasPrefix(target.rootPrefix + "/.palladium-images/"))
        XCTAssertEqual(try workspace.readFile(reference.path), gif)
        XCTAssertFalse(model.fileNames(in: target).contains(reference.path))
        XCTAssertEqual(model.librarySelections.count, 3)
    }

    @MainActor func testInvalidBatchMoveDoesNotMoveAnySource() throws {
        let (model, _, _) = try fixture()
        try model.workspace!.createFolder("Folder/Child")
        model.refreshProjectFiles([])
        model.moveLibraryItems([.note("Inicio.md"), .folder("Folder")], into: "Folder/Child", notebookID: "derecho")
        XCTAssertNotNil(model.errorText)
        XCTAssertEqual(try model.workspace!.readNote("Inicio.md"), "# Original\n")
        XCTAssertTrue(model.folders.contains("Folder/Child"))
    }

    @MainActor func testHiddenImageRemovalKeepsSharedReferencesAndRestoresOnUndo() throws {
        let (model, _, _) = try fixture()
        let gif = Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")!
        model.openNote("Inicio.md")
        let url = try model.importDocumentImage(gif, fileExtension: "gif", note: "Inicio.md")
        let path = String(url.path.dropFirst(model.workspace!.courseRoot.path.count + 1))
        XCTAssertTrue(path.hasPrefix(".palladium-images/"))
        let text = "![Picture](" + path + ")"
        model.changeDraft(text); model.saveDraft()
        try model.workspace!.createNote("Shared.md", text: text)
        model.refreshProjectFiles([])
        model.changeDraft("Removed here")
        XCTAssertEqual(try model.workspace!.readFile(path), gif)
        model.openNote("Shared.md"); model.changeDraft("Removed everywhere")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        model.changeDraft(text)
        XCTAssertEqual(try model.workspace!.readFile(path), gif)
        model.saveDraft()
        let reopened = Workbench(workspaceRoot: model.workspace!.root)
        defer { reopened.assistant?.stop(); reopened.ai?.stop(); reopened.media?.shutdown() }
        reopened.openNote("Shared.md")
        XCTAssertEqual(try reopened.workspace!.readFile(path), gif)
    }

    @MainActor func testWebPreferenceIsPerNotebookAndOlderProfilesDefaultToEnabled() throws {
        let (model, root, _) = try fixture()
        let old = try JSONDecoder().decode(NotebookProfile.self, from: Data(#"{"purpose":"","instructions":"","formatting":"","sourceRules":""}"#.utf8))
        XCTAssertTrue(old.allowsWebSearch)
        var profile = model.assistant!.state(model.currentNotebook).profile
        profile.webSearchEnabled = false
        model.assistant!.saveProfile(profile, notebook: model.currentNotebook)
        XCTAssertFalse(model.notebookWebEnabled)
        try model.createNotebookItem(kind: "cuaderno", name: "Other")
        XCTAssertTrue(model.notebookWebEnabled)
        model.openNotebook("derecho"); XCTAssertFalse(model.notebookWebEnabled)
        let reopened = Workbench(workspaceRoot: root)
        defer { reopened.assistant?.stop(); reopened.ai?.stop(); reopened.media?.shutdown() }
        reopened.openNotebook("derecho"); XCTAssertFalse(reopened.notebookWebEnabled)
    }

    @MainActor func testQuickOpenSearchIncludesNotebooksAndRevealsTheirSidebarSelection() throws {
        let (model, _, _) = try fixture()
        try model.createNotebookItem(kind: "cuaderno", name: "Álgebra")
        let notebook = model.currentNotebook
        try model.createNotebookItem(kind: "nota", name: "Álgebra")
        let path = try XCTUnwrap(model.selectedNote)
        let matches = model.quickOpenMatches(" algebra ")
        XCTAssertEqual(matches.first, .notebook(notebook.id))
        XCTAssertTrue(matches.contains(.file(path)))
        XCTAssertTrue(model.quickOpenMatches("").contains(.notebook("derecho")))
        XCTAssertTrue(model.quickOpenMatches("Preferences").contains(.preferences))
        let reveal = model.notebookRevealRequest
        model.showQuickOpen = true
        model.openQuickOpenResult(.notebook(notebook.id))
        XCTAssertFalse(model.showQuickOpen)
        XCTAssertEqual(model.librarySelection, .notebook(notebook.id))
        XCTAssertNil(model.selectedLibraryPath)
        XCTAssertEqual(model.notebookRevealRequest, reveal + 1)
        model.openQuickOpenResult(.preferences)
        XCTAssertTrue(model.showPreferences)
        model.openQuickOpenResult(.file(path))
        XCTAssertFalse(model.showPreferences)
        XCTAssertEqual(model.selectedNote, path)
        var notebooks = model.notebooks
        notebooks[try XCTUnwrap(notebooks.firstIndex(where: { $0.id == notebook.id }))].archivedAt = Date()
        model.notebooks = notebooks
        XCTAssertFalse(model.quickOpenMatches("algebra").contains(.notebook(notebook.id)))
        XCTAssertFalse(model.quickOpenMatches("algebra").contains(.file(path)))
    }

    @MainActor func testImportFolderContentsAtNotebookRootAndAsNamedNotebook() throws {
        let (model, root, _) = try fixture()
        let source = root.appendingPathComponent("external/Course")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Resources/Empty"), withIntermediateDirectories: true)
        try Data("Imported".utf8).write(to: source.appendingPathComponent("Inicio.md"))
        let binary = Data([0, 255, 19])
        try binary.write(to: source.appendingPathComponent("Resources/data.bin"))
        model.importFolderContents(source, notebookID: "derecho", asNotebook: false)
        XCTAssertNil(model.errorText)
        XCTAssertEqual(try model.workspace!.readNote("Inicio.md"), "# Original\n")
        XCTAssertEqual(try model.workspace!.readNote("Inicio copy.md"), "Imported")
        XCTAssertEqual(try model.workspace!.readFile("Resources/data.bin"), binary)
        XCTAssertTrue(model.folders.contains("Resources/Empty"))
        XCTAssertFalse(model.folders.contains("Course"))
        model.importFolderContents(source, notebookID: "derecho", asNotebook: true)
        XCTAssertNil(model.errorText)
        let notebook = model.currentNotebook
        XCTAssertEqual(notebook.name, "Course")
        XCTAssertEqual(model.librarySelection, .notebook(notebook.id))
        XCTAssertEqual(try model.workspace!.readNote(notebook.rootPrefix + "/Inicio.md"), "Imported")
        XCTAssertEqual(try model.workspace!.readFile(notebook.rootPrefix + "/Resources/data.bin"), binary)
        XCTAssertFalse(model.folders.contains(notebook.rootPrefix + "/Course"))
        model.importFolderContents(source, notebookID: "derecho", asNotebook: true)
        XCTAssertNil(model.errorText)
        XCTAssertEqual(model.currentNotebook.name, "Course 2")
        let reopened = Workbench(workspaceRoot: root)
        defer { reopened.ai?.stop(); reopened.media?.shutdown() }
        XCTAssertTrue(reopened.notebooks.contains { $0.id == notebook.id })
        XCTAssertEqual(try reopened.workspace!.readFile(notebook.rootPrefix + "/Resources/data.bin"), binary)
    }

    @MainActor func testPermanentTrashDeletionAndNotebookDeletionPreserveOtherNotebooks() throws {
        let (model, root, _) = try fixture()
        try model.createNotebookItem(kind: "nota", name: "Disposable")
        model.deleteItem("Disposable.md", folder: false)
        let entry = try XCTUnwrap(model.trash.first)
        model.permanentlyDeleteTrash(entry)
        XCTAssertNil(model.errorText)
        XCTAssertFalse(model.trash.contains { $0.id == entry.id })
        try model.createNotebookItem(kind: "cuaderno", name: "Discard")
        let discarded = model.currentNotebook
        try model.createNotebookItem(kind: "nota", name: "Nested/Example")
        try model.workspace!.createAsset(discarded.rootPrefix + "/asset.bin", data: Data([255, 0]))
        let attachment = try NotebookAttachmentImport.prepare(data: Data("Context".utf8), name: "Context.txt", notebookID: discarded.id, workspace: model.workspace!)
        model.deleteNotebook(discarded)
        model.permanentlyDeleteNotebook(discarded)
        XCTAssertNil(model.errorText)
        XCTAssertFalse(model.notebooks.contains { $0.id == discarded.id })
        XCTAssertFalse(model.projects!.checkpoints.contains { $0.notebookID == discarded.id })
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.workspace!.courseRoot.appendingPathComponent(discarded.rootPrefix).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.workspace!.storageRoot.appendingPathComponent(attachment.storagePrefix).path))
        XCTAssertEqual(try model.workspace!.readNote("Inicio.md"), "# Original\n")
        let reopened = Workbench(workspaceRoot: root)
        defer { reopened.ai?.stop(); reopened.media?.shutdown() }
        XCTAssertNil(reopened.errorText)
        XCTAssertFalse(reopened.notebooks.contains { $0.id == discarded.id })
        XCTAssertFalse(reopened.trash.contains { $0.id == entry.id })
        // Active notebooks cannot be purged by the permanent-delete action.
        reopened.permanentlyDeleteNotebook(reopened.currentNotebook)
        XCTAssertNotNil(reopened.errorText)
        XCTAssertEqual(try reopened.workspace!.readNote("Inicio.md"), "# Original\n")
    }

    @MainActor func testClearTrashPurgesArchivedNotebooksAndItemsButKeepsActiveFiles() throws {
        let (model, root, _) = try fixture()
        try model.createNotebookItem(kind: "nota", name: "Deleted note")
        model.deleteItem("Deleted note.md", folder: false)
        try model.createNotebookItem(kind: "cuaderno", name: "Deleted notebook")
        let deletedNotebook = model.currentNotebook
        try model.createNotebookItem(kind: "nota", name: "Example")
        model.deleteNotebook(deletedNotebook)
        XCTAssertFalse(model.trash.isEmpty)
        model.clearTrash()
        XCTAssertNil(model.errorText)
        XCTAssertTrue(model.trash.isEmpty)
        XCTAssertFalse(model.notebooks.contains { $0.archivedAt != nil })
        XCTAssertFalse(model.projects!.checkpoints.contains { $0.notebookID == deletedNotebook.id })
        XCTAssertEqual(try model.workspace!.readNote("Inicio.md"), "# Original\n")
        let reopened = Workbench(workspaceRoot: root)
        defer { reopened.ai?.stop(); reopened.media?.shutdown() }
        XCTAssertTrue(reopened.trash.isEmpty)
        XCTAssertFalse(reopened.notebooks.contains { $0.id == deletedNotebook.id })
        XCTAssertEqual(try reopened.workspace!.readNote("Inicio.md"), "# Original\n")
    }

    @MainActor func testImportArbitraryBytesNestedFoldersAndPDFReload() throws {
        let (model, root, _) = try fixture()
        let source = root.appendingPathComponent("external/Resources")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Empty"), withIntermediateDirectories: true)
        let bytes = Data([0, 255, 42, 0, 17])
        try bytes.write(to: source.appendingPathComponent("data.custom"))
        let image = NSImage(size: NSSize(width: 300, height: 400), flipped: false) { rect in NSColor.white.setFill(); rect.fill(); return true }
        let pdf = PDFDocument(); pdf.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        let pdfData = try XCTUnwrap(pdf.dataRepresentation()); try pdfData.write(to: source.appendingPathComponent("Guide.pdf"))
        try Data("# Imported\n".utf8).write(to: source.appendingPathComponent("Note.md"))
        model.importLibraryFiles([source], into: "", notebookID: "derecho")
        XCTAssertNil(model.errorText)
        XCTAssertEqual(try model.workspace!.readFile("Resources/data.custom"), bytes)
        XCTAssertTrue(model.folders.contains("Resources/Empty"))
        XCTAssertTrue(model.notes.contains("Resources/Note.md")); XCTAssertFalse(model.notes.contains("Resources/Guide.pdf"))
        model.openLibraryFile("Resources/Guide.pdf")
        XCTAssertEqual(model.selectedFile, "Resources/Guide.pdf"); XCTAssertNil(model.selectedNote)
        XCTAssertEqual(PDFDocument(url: try model.workspace!.fileURL("Resources/Guide.pdf"))?.pageCount, 1)
        let reopened = Workbench(workspaceRoot: root); defer { reopened.ai?.stop(); reopened.media?.shutdown() }
        XCTAssertNil(reopened.errorText); XCTAssertTrue(reopened.libraryFiles.contains("Resources/data.custom"))
        XCTAssertFalse(try reopened.projects!.texts("derecho").keys.contains("Resources/Guide.pdf"))
    }
    @MainActor func testClipboardSnapshotsDraftAndBinaryWithCollisionAndFinderPaste() throws {
        let (model, root, clipboard) = try fixture()
        model.changeDraft("# Snapshot of unsaved draft\n")
        model.copyLibraryItem(.note("Inicio.md"), to: clipboard)
        XCTAssertNotNil(clipboard.data(forType: Workbench.libraryClipboardType))
        model.changeDraft("Later revision"); model.flushAutosave()
        model.pasteLibraryItems(into: "", notebookID: "derecho", from: clipboard)
        XCTAssertNil(model.errorText)
        XCTAssertEqual(try model.workspace!.readNote("Inicio copy.md"), "# Snapshot of unsaved draft\n")
        model.pasteLibraryItems(into: "", notebookID: "derecho", from: clipboard)
        XCTAssertEqual(try model.workspace!.readNote("Inicio copy 2.md"), "# Snapshot of unsaved draft\n")
        let source = root.appendingPathComponent("Payload.bin"), bytes = Data([255, 0, 128])
        try bytes.write(to: source)
        clipboard.clearContents(); clipboard.writeObjects([source as NSURL])
        model.pasteLibraryItems(into: "", notebookID: "derecho", from: clipboard)
        XCTAssertNil(model.errorText); XCTAssertEqual(try model.workspace!.readFile("Payload.bin"), bytes)
        model.copyLibraryItem(.note("Payload.bin"), to: clipboard)
        XCTAssertNotNil(clipboard.data(forType: Workbench.libraryClipboardType))
        model.deleteItem("Payload.bin", folder: false)
        model.pasteLibraryItems(into: "", notebookID: "derecho", from: clipboard)
        XCTAssertNil(model.errorText); XCTAssertEqual(try model.workspace!.readFile("Payload.bin"), bytes)
    }
    @MainActor func testNotebookCopyIncludesProfileChatAttachmentsAndExcludesOtherNotebooks() throws {
        let (model, _, clipboard) = try fixture()
        try model.createNotebookItem(kind: "cuaderno", name: "Unrelated")
        try model.createNotebookItem(kind: "nota", name: "Private")
        model.openNotebook("derecho")
        let assistant = try XCTUnwrap(model.assistant), notebook = model.currentNotebook
        var state = assistant.state(notebook); state.profile.instructions = "Preserve profile"
        var chat = NotebookChat(title: "History"); chat.draft = "Pending draft"
        let attachment = try NotebookAttachmentImport.prepare(data: Data("Attachment text".utf8), name: "Context.txt", notebookID: notebook.id, workspace: model.workspace!)
        chat.attachments = [attachment]
        chat.messages = [.init(role: "assistant", text: "Saved", files: ["Inicio.md"], checkpointID: "old-checkpoint")]
        state.chats = [chat]; state.activeChatID = chat.id
        try assistant.installCopiedState(state, notebook: notebook)
        try model.workspace!.createAsset("manual.pdf", data: Data("original bytes".utf8))
        model.copyLibraryItem(.notebook("derecho"), to: clipboard)
        model.pasteLibraryItems(into: "", notebookID: "derecho", from: clipboard)
        XCTAssertNil(model.errorText)
        let copy = model.currentNotebook
        XCTAssertNotEqual(copy.id, notebook.id)
        XCTAssertEqual(try model.workspace!.readNote(copy.rootPrefix + "/Inicio.md"), "# Original\n")
        XCTAssertEqual(try model.workspace!.readFile(copy.rootPrefix + "/manual.pdf"), Data("original bytes".utf8))
        XCTAssertFalse(model.fileNames(in: copy).contains { $0.contains("Private") })
        let copied = assistant.state(copy)
        XCTAssertEqual(copied.profile.instructions, "Preserve profile")
        XCTAssertEqual(copied.chats.first?.draft, "Pending draft")
        XCTAssertEqual(copied.chats.first?.messages.first?.files, [copy.rootPrefix + "/Inicio.md"])
        XCTAssertNil(copied.chats.first?.messages.first?.checkpointID)
        let cloned = try XCTUnwrap(copied.chats.first?.attachments?.first)
        XCTAssertEqual(cloned.notebookID, copy.id); XCTAssertNotEqual(cloned.id, attachment.id)
        XCTAssertEqual(try model.workspace!.readStorage(cloned.storagePrefix + "/original"), Data("Attachment text".utf8))
    }
    @MainActor func testFolderMoveTrashRestoreAndConflictKeepAllBytes() throws {
        let (model, _, _) = try fixture()
        try model.createNotebookItem(kind: "carpeta", name: "Assets/Empty")
        try model.workspace!.createAsset("Assets/Blob.bin", data: Data([2, 255]))
        try model.workspace!.createNote("Assets/Note.md", text: "Note")
        model.refreshProjectFiles([])
        try model.createNotebookItem(kind: "carpeta", name: "Destination")
        model.moveLibraryItem("Assets", folder: true, into: "Destination", notebookID: "derecho")
        XCTAssertNil(model.errorText)
        XCTAssertEqual(try model.workspace!.readFile("Destination/Assets/Blob.bin"), Data([2, 255]))
        XCTAssertFalse(model.libraryFiles.contains("Assets/Blob.bin"))
        model.deleteItem("Destination/Assets", folder: true)
        let entry = try XCTUnwrap(model.trash.first)
        model.restoreTrash(entry)
        model.moveLibraryItem("Destination/Assets", folder: true, into: "", notebookID: "derecho")
        XCTAssertNil(model.errorText); XCTAssertTrue(model.folders.contains("Assets/Empty"))
        XCTAssertEqual(try model.workspace!.readNote("Assets/Note.md"), "Note")
        model.deleteItem("Assets", folder: true)
        let second = try XCTUnwrap(model.trash.first)
        try model.workspace!.createAsset("Assets/Blob.bin", data: Data([99]))
        model.restoreTrash(second)
        XCTAssertNotNil(model.errorText)
        XCTAssertEqual(try model.workspace!.readFile("Assets/Blob.bin"), Data([99]))
        XCTAssertFalse(try model.workspace!.noteNames().contains("Assets/Note.md"))
        XCTAssertTrue(model.trash.contains { $0.id == second.id })
    }
    @MainActor func testImportRejectsLinksTraversalOtherNotebookAndInvalidMarkdownBeforeWriting() throws {
        let (model, root, _) = try fixture()
        let library = NotebookFileLibrary(projects: model.projects!)
        XCTAssertThrowsError(try library.write(.init(files: ["../escape.bin": Data()]), notebookID: "derecho", summary: "Invalid"))
        XCTAssertThrowsError(try library.write(.init(files: ["good.bin": Data([1]), "bad.md": Data([255])]), notebookID: "derecho", summary: "Invalid"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("copied-course/good.bin").path))
        try model.createNotebookItem(kind: "cuaderno", name: "Other")
        XCTAssertThrowsError(try library.write(.init(files: ["Cuadernos/Other/file.bin": Data()]), notebookID: "derecho", summary: "Invalid"))
        let outside = root.appendingPathComponent("outside.bin"); try Data([22]).write(to: outside)
        let source = root.appendingPathComponent("Linked"); try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("alias.bin"), withDestinationURL: outside)
        model.importLibraryFiles([source], into: "", notebookID: "derecho")
        XCTAssertNotNil(model.errorText)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("copied-course/Linked").path))
        XCTAssertEqual(try Data(contentsOf: outside), Data([22]))
    }
}
