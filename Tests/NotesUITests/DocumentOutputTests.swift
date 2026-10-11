import XCTest
import AppKit
import PDFKit
import LectureCore
@testable import Notes

final class DocumentOutputTests: XCTestCase {
    private func environment() throws -> (SafeWorkspace, URL) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".test-workspaces/DocumentOutput-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("copied-course"), withIntermediateDirectories: true)
        return (try SafeWorkspace(root: root, originalRoot: root.appendingPathComponent("original")), root)
    }
    @MainActor func testMarkdownExportUsesNativeRenderingAndPagination() throws {
        _ = NSApplication.shared
        let (workspace, root) = try environment()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = "# Homework\n\nInline $x^2$ and **bold**.\n\n| Name | Value |\n| --- | --- |\n| Result | $\\frac{1}{2}$ |\n\n" + (1...80).map { "Paragraph \($0): a complete sentence for pagination.\n\n" }.joined()
        let view = DocumentOutput.markdownView(source, directory: workspace.courseRoot, root: workspace.courseRoot)
        XCTAssertEqual(view.string, source)
        XCTAssertFalse(view.renderedMath.isEmpty)
        XCTAssertEqual(view.renderedTables.count, 1)
        let data = try DocumentOutput.markdownPDF(source, directory: workspace.courseRoot, root: workspace.courseRoot)
        if let evidence = ProcessInfo.processInfo.environment["NOTES_PDF_EVIDENCE"] { try data.write(to: URL(fileURLWithPath: evidence), options: .atomic) }
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertGreaterThan(pdf.pageCount, 1)
        XCTAssertTrue(pdf.string?.contains("Paragraph 80") == true)
        XCTAssertTrue(pdf.string?.contains("Homework") == true)
        XCTAssertEqual(try XCTUnwrap(pdf.page(at: 0)).bounds(for: .mediaBox).height, 841.89, accuracy: 1)
    }
    @MainActor func testOutputsAreNotebookScopedAndNeverOverwrite() throws {
        _ = NSApplication.shared
        let (workspace, root) = try environment()
        defer { try? FileManager.default.removeItem(at: root) }
        try workspace.createNote("Source.md", text: "# Original\n")
        let store = try NotebookProjectStore(workspace: workspace, notebooks: [.copiedCourse])
        let notebook = Notebook.copiedCourse
        let output = NotebookDocumentOutput(path: "output/homework.tex", format: "latex", source: LaTeXDocument.template)
        let prepared = try NotebookDocumentOutputWriter.prepare([output], documents: [:], changes: [], store: store, notebook: notebook)
        try NotebookDocumentOutputWriter.publish(prepared, workspace: workspace)
        XCTAssertEqual(try workspace.readFile(output.path), Data(LaTeXDocument.template.utf8))
        XCTAssertThrowsError(try NotebookDocumentOutputWriter.prepare([output], documents: [:], changes: [], store: store, notebook: notebook))
        XCTAssertThrowsError(try NotebookDocumentOutputWriter.prepare([.init(path: "../escape.tex", format: "latex", source: "bad")], documents: [:], changes: [], store: store, notebook: notebook))
        XCTAssertThrowsError(try NotebookDocumentOutputWriter.prepare([.init(path: "output/unread.pdf", sourcePath: "Source.md", format: "pdf")], documents: [:], changes: [], store: store, notebook: notebook))
        XCTAssertThrowsError(try NotebookDocumentOutputWriter.prepare([.init(path: "output/stale.pdf", sourcePath: "Source.md", format: "pdf")], documents: ["Source.md": "stale"], changes: [], store: store, notebook: notebook))
    }
    @MainActor func testLaTeXDraftSurvivesReloadAndDetectsExternalChanges() throws {
        let (workspace, root) = try environment()
        defer { try? FileManager.default.removeItem(at: root) }
        try workspace.createAsset("Homework.tex", data: Data(LaTeXDocument.template.utf8))
        let controller = LaTeXEditorController(workspace: workspace, path: "Homework.tex")
        controller.change(LaTeXDocument.template + "\n% edited")
        let restored = LaTeXEditorController(workspace: workspace, path: "Homework.tex")
        XCTAssertEqual(restored.source, controller.source); XCTAssertTrue(restored.dirty)
        try restored.save(); XCTAssertFalse(restored.dirty)
        restored.change("my draft")
        try "external change".write(to: workspace.fileURL("Homework.tex"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try restored.save())
        XCTAssertEqual(restored.source, "my draft")
    }
    @MainActor func testLaTeXTemplateCompilesWithLocalTectonic() async throws {
        guard ProcessInfo.processInfo.environment["NOTES_TEST_LATEX"] == "1" else { throw XCTSkip("Opt in with NOTES_TEST_LATEX=1 to exercise the real local compiler.") }
        let data = try await LaTeXDocument.compile(LaTeXDocument.template)
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(pdf.pageCount, 1)
        XCTAssertTrue(pdf.string?.contains("Homework") == true)
    }
}
