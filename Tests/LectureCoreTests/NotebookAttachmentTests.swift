import XCTest
import PDFKit
@testable import LectureCore

final class NotebookAttachmentTests: XCTestCase {
    private func workspace() throws -> SafeWorkspace {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".test-workspaces/NotesAttachment-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("copied-course"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try SafeWorkspace(root: root, originalRoot: root.appendingPathComponent("original"))
    }
    func testFencedStructuredReplyIsAcceptedWithoutAcceptingProse() throws {
        let json = "{\"reply\":\"A red circle\",\"readFiles\":[],\"articles\":[],\"edits\":[]}"
        XCTAssertEqual(try NotebookAssistantProtocol.decode("```json\n" + json + "\n```").reply, "A red circle")
        XCTAssertThrowsError(try NotebookAssistantProtocol.decode("Here is the result: " + json))
    }
    func testTextRetainsExactContentsAndPrivateCopy() throws {
        let workspace = try workspace(), text = "# Invented fixture\n- [ ] Read chapter\n"
        let attachment = try NotebookAttachmentImport.prepare(data: Data(text.utf8), name: "Reading.md", notebookID: "derecho", workspace: workspace)
        XCTAssertEqual(attachment.text, text)
        XCTAssertEqual(try workspace.readStorage(attachment.storagePrefix + "/original"), Data(text.utf8))
        XCTAssertTrue(try workspace.noteNames().isEmpty)
        XCTAssertThrowsError(try NotebookAttachmentImport.images([attachment], notebookID: "other", workspace: workspace))
    }
    func testImageAndPDFPreparation() throws {
        let workspace = try workspace()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let image = try NotebookAttachmentImport.prepare(data: png, name: "Figure.png", notebookID: "derecho", workspace: workspace)
        XCTAssertEqual(image.imageCount, 1)
        XCTAssertFalse(try NotebookAttachmentImport.images([image], notebookID: "derecho", workspace: workspace)[0].data.isEmpty)
        let pdf = PDFDocument()
        pdf.insert(try XCTUnwrap(PDFPage(image: try XCTUnwrap(NSImage(data: png)))), at: 0)
        let attachment = try NotebookAttachmentImport.prepare(data: try XCTUnwrap(pdf.dataRepresentation()), name: "Scanned.pdf", notebookID: "derecho", workspace: workspace)
        XCTAssertTrue(attachment.isPDF)
        XCTAssertEqual(attachment.imageCount, 1)
        XCTAssertTrue(attachment.text.contains("[Page 1]"))
    }
    func testRejectUnsupportedOversizeAndMalformedFiles() throws {
        let workspace = try workspace()
        for name in ["program.app", "archive.zip", "fake.pdf", "fake.png"] {
            XCTAssertThrowsError(try NotebookAttachmentImport.prepare(data: Data("not a file".utf8), name: name, notebookID: "derecho", workspace: workspace))
        }
        XCTAssertThrowsError(try NotebookAttachmentImport.prepare(data: Data(repeating: 1, count: NotebookAttachmentImport.maximumBytes + 1), name: "large.txt", notebookID: "derecho", workspace: workspace))
        XCTAssertThrowsError(try NotebookAttachmentImport.prepare(data: Data(repeating: 65, count: 180_001), name: "long.txt", notebookID: "derecho", workspace: workspace))
    }
}
