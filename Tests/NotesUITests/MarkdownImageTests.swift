import XCTest
import AppKit
@testable import Notes

final class MarkdownImageTests: XCTestCase {
    @MainActor func testLocalImageRenderingPreservesSourceAndRejectsOutsideFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MarkdownImage-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 20, pixelsHigh: 10, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try rep.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("image.png"))
        let text = "# Picture\n\n![Local image](image.png)\n\nAfter the image.\n\n![Remote](https://example.com/a.png)\n"
        let view = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.imageDirectory = root; view.imageRoot = root; view.string = text; view.liveEditing = false; view.renderMarkdown()
        XCTAssertEqual(view.string, text); XCTAssertEqual(view.renderedImages.count, 1)
        XCTAssertTrue(MarkdownImageRenderer.render(source: "![Escape](../image.png)", directory: root, root: root, width: 600).isEmpty)
        view.liveEditing = true; view.setSelectedRange(NSRange(location: view.renderedImages[0].range.location + 3, length: 0)); view.renderMarkdown()
        XCTAssertEqual(view.renderedImages.count, 1, "Image remains visual while editing"); XCTAssertEqual(view.string, text)
    }
    @MainActor func testPastedImageResizeCropResetAndUndoKeepOriginalAsset() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DocumentImage-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 400, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let data = rep.representation(using: .png, properties: [:])!
        let board = NSPasteboard.withUniqueName(); board.setData(data, forType: .png)
        defer { board.releaseGlobally() }
        let view = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.imageDirectory = root; view.imageRoot = root; view.string = "# Pictures\n\n"; view.liveEditing = true; view.isEditable = true
        var imports = 0
        view.importImage = { bytes, ext in
            imports += 1
            let url = root.appendingPathComponent("pasted.\(ext)"); try bytes.write(to: url); return url
        }
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0)); view.renderMarkdown()
        XCTAssertTrue(view.insertImages(from: board))
        XCTAssertEqual(imports, 1); XCTAssertEqual(view.renderedImages.count, 1)
        let inserted = view.string, location = try XCTUnwrap(view.renderedImages.first).range.location
        let original = try Data(contentsOf: root.appendingPathComponent("pasted.png"))
        view.changeImage(at: location, width: 240, crop: NSRect(x: 0.1, y: 0.2, width: 0.5, height: 0.5))
        XCTAssertEqual(view.renderedImages.first?.size.width, 240)
        XCTAssertEqual(view.renderedImages.first?.crop.width, 0.5)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("pasted.png")), original)
        view.undo(nil); view.renderMarkdown(); XCTAssertEqual(view.string, inserted)
        view.redo(nil); view.renderMarkdown(); XCTAssertEqual(view.renderedImages.first?.crop.width, 0.5)
        view.changeImage(at: location, width: nil, crop: NSRect(x: 0, y: 0, width: 1, height: 1)); XCTAssertEqual(view.string, inserted)
        view.selectImage(at: location); view.removeSelectedImage(); XCTAssertTrue(view.renderedImages.isEmpty)
        view.undo(nil); view.renderMarkdown(); XCTAssertEqual(view.renderedImages.count, 1)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("pasted.png")), original)
    }
    @MainActor func testFileClipboardPreservesGIFAndReadModeDoesNotInsert() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GIFClipboard-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let gif = Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")!
        let url = root.appendingPathComponent("source.gif"); try gif.write(to: url)
        let board = NSPasteboard.withUniqueName(); board.writeObjects([url as NSURL]); defer { board.releaseGlobally() }
        XCTAssertTrue(DocumentImageInput.containsImage(board))
        XCTAssertEqual(try DocumentImageInput.read(board).first?.data, gif)
        XCTAssertEqual(try DocumentImageInput.read(board).first?.fileExtension, "gif")
        let presentation = DocumentImagePresentation(sourceURL: url.absoluteString, width: 240, crop: [0.1, 0.2, 0.5, 0.5])
        board.setData(try JSONEncoder().encode(presentation), forType: DocumentImagePresentation.pasteboardType)
        XCTAssertTrue(try XCTUnwrap(DocumentImageInput.read(board).first?.presentation?.metadata).contains("width=240.0"))
        XCTAssertNil(DocumentImagePresentation(sourceURL: url.absoluteString, width: 240, crop: [-1, 0, 1, 1]).metadata)
        let view = MarkdownTextView(frame: .zero); view.isEditable = false
        XCTAssertFalse(view.insertImages(from: board)); XCTAssertEqual(view.string, "")
    }

    @MainActor func testVisualResizeAndCropControlsEmitGeometry() throws {
        let image = NSImage(size: NSSize(width: 600, height: 400))
        let render = RenderedMarkdownImage(range: NSRange(location: 0, length: 15), image: image, url: URL(fileURLWithPath: "/invented.png"), markdown: "![Image](a.png)", crop: NSRect(x: 0, y: 0, width: 1, height: 1), requestedWidth: nil, size: NSSize(width: 600, height: 400))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = MarkdownImageView(frame: NSRect(x: 0, y: 0, width: 600, height: 400)); view.editable = true; view.configure(render)
        window.contentView!.addSubview(view); view.layoutSubtreeIfNeeded()
        var changedWidth: CGFloat?, changedCrop: NSRect?
        view.onChange = { changedWidth = $0; changedCrop = $1 }
        let overlay = view.subviews[1]
        func event(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        overlay.mouseDown(with: event(.leftMouseDown, NSPoint(x: 596, y: 396)))
        overlay.mouseDragged(with: event(.leftMouseDragged, NSPoint(x: 296, y: 196)))
        overlay.mouseUp(with: event(.leftMouseUp, NSPoint(x: 296, y: 196)))
        XCTAssertEqual(changedWidth, 300); XCTAssertEqual(changedCrop, render.crop)
        func button(_ name: String) throws -> NSButton {
            try XCTUnwrap(view.subviews.flatMap(\.subviews).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "document.image." + name })
        }
        try button("crop").performClick(nil); view.layoutSubtreeIfNeeded()
        overlay.mouseDown(with: event(.leftMouseDown, NSPoint(x: 30, y: 20)))
        overlay.mouseDragged(with: event(.leftMouseDragged, NSPoint(x: 180, y: 120)))
        overlay.mouseUp(with: event(.leftMouseUp, NSPoint(x: 180, y: 120)))
        try button("checkmark").performClick(nil)
        XCTAssertEqual(changedWidth, 150)
        XCTAssertEqual(try XCTUnwrap(changedCrop).minX, 0.1, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(changedCrop).width, 0.5, accuracy: 0.001)
    }

}
