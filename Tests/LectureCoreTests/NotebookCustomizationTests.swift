import XCTest
@testable import LectureCore

final class NotebookCustomizationTests: XCTestCase {
    func testInstructionsAndSkillsAreScopedAndAlwaysLoaded() throws {
        let notebook = Notebook(id: "accounting", name: "Contabilidad", rootPrefix: "Cuadernos/Contabilidad")
        let agent = NotebookCustomization.agentPath(notebook)
        let skill = NotebookCustomization.skillsPrefix(notebook) + "asientos/SKILL.md"
        let texts = [agent: "Use Spanish accounting rules", skill: "Balance Debe and Haber",
                     "AGENTS.md": "Root instructions", "skills/global/SKILL.md": "Foreign skill",
                     "Cuadernos/Other/AGENTS.md": "Other instructions",
                     "Cuadernos/Contabilidad/skills/asientos/example.md": "Source, not a skill",
                     "Cuadernos/Contabilidad/Notes.md": "# Ordinary source"]
        let request = NotebookTextRequest(notebook: notebook, profile: .init(), messages: [.init(role: "user", text: "Hello")], currentDocument: nil, texts: texts)
        XCTAssertEqual(request.notebookInstructions, [agent: texts[agent]!, skill: texts[skill]!])
        XCTAssertEqual(request.documents[agent], texts[agent]); XCTAssertEqual(request.documents[skill], texts[skill])
        let prompt = try request.prompt()
        XCTAssertTrue(prompt.contains("notebookInstructions")); XCTAssertTrue(prompt.contains("AGENTS.md supersedes"))
        XCTAssertFalse(NotebookCustomization.isSkill("Cuadernos/Contabilidad/skills/../SKILL.md", notebook: notebook))
    }
    func testOldProfilesCanBePreservedInTheInstructionsFile() throws {
        let profile = try JSONDecoder().decode(NotebookProfile.self, from: Data(#"{"purpose":"Accounting","instructions":"Use Spanish","formatting":"Tables","sourceRules":"Cite notes"}"#.utf8))
        let text = NotebookCustomization.initialInstructions(profile: profile)
        for value in ["Accounting", "Use Spanish", "Tables", "Cite notes"] { XCTAssertTrue(text.contains(value)) }
        XCTAssertTrue(profile.allowsWebSearch)
    }
    func testLegacyCheckpointRestorationPreservesNewHTMLViews() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".test-workspaces/NotebookHTML-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("copied-course"), withIntermediateDirectories: true)
        let workspace = try SafeWorkspace(root: root, originalRoot: root.appendingPathComponent("original"))
        try workspace.createNote("Note.md", text: "Original")
        let store = try NotebookProjectStore(workspace: workspace, notebooks: [.copiedCourse])
        let checkpoint = try store.capture("derecho", summary: "Legacy")
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(checkpoint)) as! [String: Any]
        json.removeValue(forKey: "tracksCustomUI")
        let legacy = try JSONDecoder().decode(NotebookCheckpoint.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.tracksCustomUI)
        try workspace.writeStorage("projects/checkpoints.json", data: JSONEncoder().encode([legacy]))
        let reopened = try NotebookProjectStore(workspace: workspace, notebooks: [.copiedCourse])
        try workspace.createAsset("Entries.ui.html", data: Data("<h1>Keep this view</h1>".utf8))
        _ = try reopened.apply("derecho", summary: "Edit", changes: [.init(path: "Note.md", before: "Original", after: "Changed")])
        _ = try reopened.restore(legacy)
        XCTAssertEqual(try workspace.readNote("Note.md"), "Original")
        XCTAssertEqual(try workspace.readNote("Entries.ui.html"), "<h1>Keep this view</h1>")
    }
    func testHTMLValidationAndFrameIsolation() throws {
        XCTAssertThrowsError(try NotebookCustomUI.validate("  "))
        XCTAssertThrowsError(try NotebookCustomUI.validate(String(repeating: "x", count: 1_000_001)))
        XCTAssertThrowsError(try NotebookCustomUI.validate("<p>\0</p>"))
        let html = NotebookCustomUI.document(source: "</iframe><script>parent.hacked=true</script>", theme: ["mode": "dark"])
        XCTAssertTrue(html.contains("sandbox=\"allow-scripts\""))
        XCTAssertFalse(html.contains("allow-same-origin"))
        XCTAssertTrue(html.contains("connect-src 'none'")); XCTAssertTrue(html.contains("form-action 'none'"))
        XCTAssertFalse(html.contains("</iframe><script>"))
    }
}
