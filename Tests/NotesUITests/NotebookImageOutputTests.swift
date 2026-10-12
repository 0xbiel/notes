import XCTest
import AppKit
import PDFKit
import LectureCore
@testable import Notes

final class NotebookImageOutputTests: XCTestCase {
    private func workspace() throws -> SafeWorkspace {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".test-workspaces/ImageOutput-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("copied-course"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try SafeWorkspace(root: root, originalRoot: root.appendingPathComponent("original"))
    }
    private func image() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 80, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for row in 0..<80 {
            for column in 0..<100 {
                var components = row < 40 ? [255, 0, 0, 255] : [0, 0, 255, 255]
                bitmap.setPixel(&components, atX: column, y: row)
            }
        }
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
    func testCropsUseTopLeftCoordinatesAndRejectInvalidRegions() throws {
        let data = try image()
        let result = try NotebookSourceImage.png(data, filename: "source.png", crop: .init(x: 0, y: 0, width: 0.5, height: 0.5))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: result))
        XCTAssertEqual(bitmap.pixelsWide, 50); XCTAssertEqual(bitmap.pixelsHigh, 40)
        let color = try XCTUnwrap(bitmap.colorAt(x: 10, y: 10)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(color.redComponent, 0.9); XCTAssertLessThan(color.blueComponent, 0.1)
        for crop in [NotebookImageCrop(x: -0.1, y: 0, width: 1, height: 1), .init(x: 0, y: 0, width: 0, height: 1), .init(x: 0.8, y: 0, width: 0.5, height: 1), .init(x: .nan, y: 0, width: 1, height: 1)] {
            XCTAssertThrowsError(try NotebookSourceImage.png(data, filename: "source.png", crop: crop))
        }
        XCTAssertThrowsError(try NotebookSourceImage.png(data, filename: "source.png", page: 1))
    }
    @MainActor func testPDFsWithTextExposeVisualPagesAndCanBeCroppedIntoNotes() throws {
        _ = NSApplication.shared
        let workspace = try workspace()
        let data = try DocumentOutput.markdownPDF("# Selectable text\n\nA page containing text and formulas $x^2$.", directory: workspace.courseRoot, root: workspace.courseRoot)
        try workspace.createAsset("Source.pdf", data: data)
        let store = try NotebookProjectStore(workspace: workspace, notebooks: [.copiedCourse])
        let context = try NotebookLibraryContext.read("Source.pdf", selection: .pages(1...1), library: NotebookFileLibrary(projects: store), notebookID: Notebook.copiedCourse.id)
        XCTAssertTrue(context.text.contains("Selectable text")); XCTAssertEqual(context.images.count, 1)
        let output = NotebookDocumentOutput(path: ".palladium-images/figure.png", sourcePath: "Source.pdf", format: "image", page: 1, crop: .init(x: 0, y: 0, width: 1, height: 0.3))
        let prepared = try NotebookDocumentOutputWriter.prepare([output], documents: ["Source.pdf#pages=1": context.text], changes: [], store: store, notebook: .copiedCourse, sourceDigests: ["Source.pdf": try XCTUnwrap(context.sourceDigest)])
        try NotebookDocumentOutputWriter.publish(prepared, workspace: workspace)
        let source = "# Extracted figure\n\n![Original figure](.palladium-images/figure.png)\n"
        let view = DocumentOutput.markdownView(source, directory: workspace.courseRoot, root: workspace.courseRoot)
        XCTAssertEqual(view.renderedImages.count, 1)
        XCTAssertEqual(try workspace.readFile("Source.pdf"), data)
        XCTAssertThrowsError(try NotebookDocumentOutputWriter.prepare([output], documents: ["Source.pdf": context.text], changes: [], store: store, notebook: .copiedCourse, sourceDigests: ["Source.pdf": context.sourceDigest!]))
        XCTAssertThrowsError(try NotebookSourceImage.png(data, filename: "Source.pdf", page: 2))
    }
    @MainActor func testSourceValidationPreventsUnreadStaleAndForeignAttachmentOutputs() throws {
        let workspace = try workspace(), data = try image()
        try workspace.createAsset("Source.png", data: data)
        let store = try NotebookProjectStore(workspace: workspace, notebooks: [.copiedCourse])
        let output = NotebookDocumentOutput(path: "figure.png", sourcePath: "Source.png", format: "image")
        XCTAssertThrowsError(try NotebookDocumentOutputWriter.prepare([output], documents: [:], changes: [], store: store, notebook: .copiedCourse, sourceDigests: ["Source.png": NotebookSourceImage.digest(data)]))
        XCTAssertThrowsError(try NotebookDocumentOutputWriter.prepare([output], documents: ["Source.png": "read"], changes: [], store: store, notebook: .copiedCourse, sourceDigests: ["Source.png": "stale"]))
        let attachment = try NotebookAttachmentImport.prepare(data: data, name: "Attached.png", notebookID: Notebook.copiedCourse.id, workspace: workspace)
        let path = "attachment:" + attachment.id
        let attached = NotebookDocumentOutput(path: "attached.png", sourcePath: path, format: "image", crop: .init(x: 0, y: 0, width: 0.5, height: 1))
        let prepared = try NotebookDocumentOutputWriter.prepare([attached], documents: [:], changes: [], store: store, notebook: .copiedCourse, sourceDigests: [path: NotebookSourceImage.digest(data)], attachments: [attachment])
        try NotebookDocumentOutputWriter.publish(prepared, workspace: workspace)
        XCTAssertEqual(try XCTUnwrap(NSBitmapImageRep(data: workspace.readFile("attached.png"))).pixelsWide, 50)
        try NotebookDocumentOutputWriter.rollback(prepared, workspace: workspace)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try workspace.fileURL("attached.png").path))
        XCTAssertThrowsError(try NotebookDocumentOutputWriter.prepare([attached], documents: [:], changes: [], store: store, notebook: .copiedCourse, sourceDigests: [path: NotebookSourceImage.digest(data)], attachments: []))
    }

    @MainActor func testQuizOutputsRejectMissingAndNonImageReferenceAssets() throws {
        let workspace = try workspace()
        let store = try NotebookProjectStore(workspace: workspace, notebooks: [.copiedCourse])
        var test = NotebookPracticeTest(title: "Figure test", instructions: "Choose one.", questions: [
            .init(id: "figure", prompt: "Which region is marked?", options: [
                .init(id: "a", text: "Region A", explanation: "The mark is inside A."),
                .init(id: "b", text: "Region B", explanation: "B contains no mark.")
            ], correctOptionID: "a", explanation: "Match the visible label.", images: [.init(path: "missing.png", alt: "Labelled regions")])
        ])
        XCTAssertThrowsError(try NotebookDocumentOutputWriter.prepare([.init(path: "Figure.quiz.json", format: "quiz", test: test)], documents: [:], changes: [], store: store, notebook: .copiedCourse))
        try workspace.createAsset("not-image.png", data: Data("Not an image".utf8))
        test.questions[0].images = [.init(path: "not-image.png", alt: "Labelled regions")]
        XCTAssertThrowsError(try NotebookDocumentOutputWriter.prepare([.init(path: "Figure.quiz.json", format: "quiz", test: test)], documents: [:], changes: [], store: store, notebook: .copiedCourse))
        XCTAssertFalse(FileManager.default.fileExists(atPath: try workspace.fileURL("Figure.quiz.json").path))
    }
}
