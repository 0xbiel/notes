import XCTest
@testable import LectureCore

final class NotebookProjectTests: XCTestCase {
    private func fixture() throws -> (SafeWorkspace, NotebookProjectStore, URL) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".test-workspaces/NotebookProject-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("copied-course"), withIntermediateDirectories: true)
        let workspace = try SafeWorkspace(root: root, originalRoot: root.appendingPathComponent("original"))
        try workspace.createNote("One.md", text: "One")
        let store = try NotebookProjectStore(workspace: workspace, notebooks: [.copiedCourse, Notebook(id: "other", name: "Other", rootPrefix: "Cuadernos/Other")])
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (workspace, store, root)
    }
    func testGroupedEditsCreationRestoreAndReload() throws {
        let (workspace, store, _) = try fixture()
        let initial = try store.capture("derecho", summary: "Initial")
        let edited = try store.apply("derecho", summary: "Two changes", changes: [.init(path: "One.md", before: "One", after: "New"), .init(path: "Folder/Two.md", before: nil, after: "Two")])
        XCTAssertEqual(edited.changedFiles, ["Folder/Two.md", "One.md"])
        let restored = try store.restore(initial)
        XCTAssertEqual(try workspace.noteNames(), ["One.md"])
        XCTAssertEqual(try workspace.readNote("One.md"), "One")
        XCTAssertNotEqual(restored.id, initial.id)
        _ = try store.restore(edited)
        XCTAssertEqual(try workspace.readNote("Folder/Two.md"), "Two")
        let reloaded = try NotebookProjectStore(workspace: workspace, notebooks: store.notebooks)
        XCTAssertEqual(reloaded.checkpoints.count, 4)
        XCTAssertEqual(try reloaded.content(edited.files["One.md"]!), "New")
    }
    func testIsolationTraversalAliasAndStaleEdits() throws {
        let (workspace, store, _) = try fixture()
        try workspace.createNote("Cuadernos/Other/Secret.md", text: "Other notebook")
        XCTAssertEqual(try store.texts("derecho"), ["One.md": "One"])
        for path in ["../Escape.md", "Cuadernos/Other/Secret.md", "/tmp/Escape.md", "one.md"] {
            XCTAssertThrowsError(try store.apply("derecho", summary: "Unsafe", changes: [.init(path: path, before: nil, after: "No")]))
        }
        XCTAssertThrowsError(try store.apply("derecho", summary: "Stale", changes: [.init(path: "One.md", before: "Old", after: "No")]))
        XCTAssertEqual(try workspace.readNote("One.md"), "One")
    }
    func testFailedSecondWriteRollsBackEntireGroup() throws {
        let (workspace, store, _) = try fixture()
        var fail = true
        workspace.noteMutation = { path, _, _ in
            if path == "Two.md", fail { fail = false; throw MediaError.invalid("Injected disk failure") }
            return false
        }
        XCTAssertThrowsError(try store.apply("derecho", summary: "Failure", changes: [.init(path: "One.md", before: "One", after: "Changed"), .init(path: "Two.md", before: nil, after: "Two")]))
        XCTAssertEqual(try workspace.readNote("One.md"), "One")
        XCTAssertEqual(try workspace.noteNames(), ["One.md"])
        XCTAssertEqual(store.checkpoints.count, 1)
    }
    func testInterruptedTransactionRollsBackAndCommittedTransactionFinishes() throws {
        let (workspace, store, _) = try fixture()
        _ = try store.capture("derecho", summary: "Initial")
        let changes = [NotebookFileChange(path: "One.md", before: "One", after: "Changed"), .init(path: "Two.md", before: nil, after: "Two")]
        let pending = NotebookCheckpoint(notebookID: "derecho", summary: "Interrupted", files: [:], changedFiles: ["One.md", "Two.md"])
        try workspace.writeStorage("projects/transaction.json", data: JSONEncoder().encode(NotebookTransaction(checkpoint: pending, changes: changes)))
        try workspace.writeNote("One.md", expected: "One", replacement: "Changed")
        _ = try NotebookProjectStore(workspace: workspace, notebooks: store.notebooks)
        XCTAssertEqual(try workspace.readNote("One.md"), "One")
        let committed = try store.apply("derecho", summary: "Committed", changes: changes)
        try workspace.writeStorage("projects/transaction.json", data: JSONEncoder().encode(NotebookTransaction(checkpoint: committed, changes: changes)))
        let reloaded = try NotebookProjectStore(workspace: workspace, notebooks: store.notebooks)
        XCTAssertEqual(reloaded.timeline("derecho").last?.id, committed.id)
        XCTAssertEqual(try workspace.readNote("One.md"), "Changed")
    }
    func testRecoveryRefusesExternalConflictAndDoesNotOverwriteJournal() throws {
        let (workspace, store, _) = try fixture()
        let pending = NotebookCheckpoint(notebookID: "derecho", summary: "Interrupted", files: [:], changedFiles: ["One.md"])
        let data = try JSONEncoder().encode(NotebookTransaction(checkpoint: pending, changes: [.init(path: "One.md", before: "Old", after: "Changed")]))
        try workspace.writeStorage("projects/transaction.json", data: data)
        XCTAssertThrowsError(try store.apply("derecho", summary: "New", changes: [.init(path: "One.md", before: "One", after: "Oops")]))
        XCTAssertEqual(try workspace.readStorage("projects/transaction.json"), data)
        XCTAssertEqual(try workspace.readNote("One.md"), "One")
    }
    func testManualTrackingAndIndependentStates() throws {
        let (workspace, store, _) = try fixture()
        store.installWriteTracking()
        try workspace.writeNote("One.md", expected: "One", replacement: "Manual")
        XCTAssertEqual(store.timeline("derecho").count, 2)
        var state = NotebookProjectState(); state.profile.instructions = "Use headings"; state.chats = [.init(title: "First")]; state.activeChatID = state.chats[0].id
        try store.saveState(state, notebookID: "derecho")
        XCTAssertEqual(try store.loadState(.copiedCourse), state)
        XCTAssertTrue(try store.loadState(store.notebooks[1]).chats.isEmpty)
    }
    func testAssistantUsesUniqueAnchorsAndProviderContentWithoutLegalResolver() throws {
        let response = NotebookAssistantResponse(reply: "Done", edits: [.init(path: "One.md", find: "One", replacement: "One\n\nProvider content with citation")])
        let changes = try NotebookAssistantProtocol.changes(response, documents: ["One.md": "One"])
        XCTAssertEqual(changes[0].after, "One\n\nProvider content with citation")
        XCTAssertThrowsError(try NotebookAssistantProtocol.changes(response, documents: ["One.md": "One One"]))
        XCTAssertFalse((NotebookAssistantProtocol.schema["properties"] as? [String: Any])?.keys.contains("articles") == true)
        let arguments = NotesProviderTransport.codexArguments(AIProviderConfiguration(provider: .codexCLI, executablePath: "/usr/bin/false"), schema: URL(fileURLWithPath: "/tmp/response.json"), instructions: NotebookAssistantProtocol.instructions, allowWebSearch: true)
        XCTAssertTrue(arguments.contains("web_search=\"live\""))
        XCTAssertTrue(arguments.contains("read-only")); XCTAssertTrue(arguments.contains("shell_tool"))
        let legacy = Data("{\"purpose\":\"Saved\",\"instructions\":\"Keep\",\"formatting\":\"\",\"sourceRules\":\"Cite\",\"resolveArticles\":true}".utf8)
        let profile = try JSONDecoder().decode(NotebookProfile.self, from: legacy)
        XCTAssertEqual(profile.instructions, "Keep")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(profile), as: UTF8.self).contains("resolveArticles"))
    }
}
