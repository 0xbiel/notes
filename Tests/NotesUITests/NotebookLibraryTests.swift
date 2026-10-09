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
        let entry = try XCTUnwrap(model.trash.first)
        model.restoreTrash(entry)
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
