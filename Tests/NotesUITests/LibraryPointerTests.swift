import XCTest
import AppKit
import SwiftUI
import LectureCore
@testable import Notes

/// Drives the real sidebar with pointer events, as the event monitor would.
final class LibraryPointerTests: XCTestCase {
    @MainActor private struct Sidebar {
        let model: Workbench
        let window: NSWindow
        let outline: NSOutlineView
        let bridge: NeutralSidebarSelection.SelectionBridge
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.15)); window.contentView?.layoutSubtreeIfNeeded() }
        func row(_ item: NotebookSidebarSelection) throws -> Int {
            try XCTUnwrap(LibraryRowMarker.items(in: outline).first { $0.value == item }?.key, "no row for \(item)")
        }
        func point(_ item: NotebookSidebarSelection, dx: CGFloat = 0, dy: CGFloat = 0) throws -> NSPoint {
            // On the name; the space beside it sweeps a selection instead.
            let row = try row(item), rect = outline.rect(ofRow: row)
            let end = try XCTUnwrap(LibraryRowMarker.labelEnd(row: row, in: outline))
            return outline.convert(NSPoint(x: end - 12 + dx, y: rect.midY + dy), to: nil)
        }
        func blank(_ item: NotebookSidebarSelection) throws -> NSPoint {
            let rect = outline.rect(ofRow: try row(item))
            return outline.convert(NSPoint(x: rect.maxX - 24, y: rect.midY), to: nil)
        }
        @discardableResult func send(_ type: NSEvent.EventType, _ location: NSPoint, _ flags: NSEvent.ModifierFlags = []) -> Bool {
            let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            return bridge.handlePointer(event) == nil
        }
        func click(_ item: NotebookSidebarSelection, _ flags: NSEvent.ModifierFlags = []) throws {
            let location = try point(item)
            XCTAssertTrue(send(.leftMouseDown, location, flags)); XCTAssertTrue(send(.leftMouseUp, location, flags)); settle()
        }
        func drag(_ item: NotebookSidebarSelection, to target: NotebookSidebarSelection, release: Bool = true) throws {
            let start = try point(item), end = try point(target)
            XCTAssertTrue(send(.leftMouseDown, start))
            XCTAssertTrue(send(.leftMouseDragged, NSPoint(x: start.x + 2, y: start.y)))
            XCTAssertNil(bridge.press?.items, "a drag began inside the click threshold")
            XCTAssertTrue(send(.leftMouseDragged, NSPoint(x: start.x + 9, y: start.y)))
            XCTAssertTrue(send(.leftMouseDragged, end))
            if release { XCTAssertTrue(send(.leftMouseUp, end)); settle() }
        }
    }

    @MainActor private func sidebar() throws -> Sidebar {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".test-workspaces/Pointer-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("copied-course"), withIntermediateDirectories: true)
        for name in ["Alpha", "Beta", "Delta", "Gamma"] { try Data("# \(name)\n".utf8).write(to: root.appendingPathComponent("copied-course/\(name).md")) }
        try JSONSerialization.data(withJSONObject: ["originalRoot": root.appendingPathComponent("original").path]).write(to: root.appendingPathComponent("original-hashes.json"))
        let model = Workbench(workspaceRoot: root)
        XCTAssertNil(model.errorText)
        try model.workspace!.createFolder("Archive/Inner")
        try model.workspace!.createNote("Archive/Old.md", text: "Old")
        model.refreshProjectFiles([])
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: CourseSidebar(model: model).frame(width: 300, height: 700))
        addTeardownBlock { @MainActor in
            window.close()
            model.assistant?.stop(); model.ai?.stop(); model.media?.shutdown()
            model.autosaveTasks.values.forEach { $0.cancel() }
            try? FileManager.default.removeItem(at: root)
        }
        func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? { (view as? T) ?? view.subviews.lazy.compactMap { find(type, in: $0) }.first }
        var outline: NSOutlineView?, bridge: NeutralSidebarSelection.SelectionBridge?
        for _ in 0..<20 where outline == nil || bridge?.table == nil {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1)); window.contentView?.layoutSubtreeIfNeeded()
            outline = find(NSOutlineView.self, in: window.contentView!)
            bridge = find(NeutralSidebarSelection.SelectionBridge.self, in: window.contentView!)
            bridge?.connect()
        }
        let sidebar = Sidebar(model: model, window: window, outline: try XCTUnwrap(outline), bridge: try XCTUnwrap(bridge))
        sidebar.settle()
        return sidebar
    }

    @MainActor func testClickOpensAndCommandClickBuildsGroupWithoutSwitchingDocument() throws {
        let sidebar = try sidebar(), model = sidebar.model
        try sidebar.click(.note("Beta.md"))
        XCTAssertEqual(model.selectedNote, "Beta.md")
        XCTAssertEqual(model.librarySelections, [.note("Beta.md")])
        try sidebar.click(.note("Gamma.md"), .command)
        XCTAssertEqual(model.librarySelections, [.note("Beta.md"), .note("Gamma.md")])
        XCTAssertEqual(model.selectedNote, "Beta.md")
        XCTAssertEqual(sidebar.outline.selectedRowIndexes, IndexSet([try sidebar.row(.note("Beta.md")), try sidebar.row(.note("Gamma.md"))]))
        try sidebar.click(.note("Gamma.md"), .command)
        XCTAssertEqual(model.librarySelections, [.note("Beta.md")])
        // A plain click on one row of a group reduces the group on release.
        try sidebar.click(.note("Alpha.md"), .command)
        try sidebar.click(.note("Alpha.md"))
        XCTAssertEqual(model.librarySelections, [.note("Alpha.md")])
        XCTAssertEqual(model.selectedNote, "Alpha.md")
    }

    @MainActor func testShiftClickSelectsRange() throws {
        let sidebar = try sidebar(), model = sidebar.model
        try sidebar.click(.note("Alpha.md"))
        try sidebar.click(.note("Delta.md"), .shift)
        XCTAssertEqual(model.librarySelections, [.note("Alpha.md"), .note("Beta.md"), .note("Delta.md")])
        XCTAssertEqual(model.selectedNote, "Alpha.md")
        try sidebar.click(.note("Beta.md"), .shift)
        XCTAssertEqual(model.librarySelections, [.note("Alpha.md"), .note("Beta.md")])
    }

    @MainActor func testDraggingGroupMovesEveryItemAndHighlightsDestination() throws {
        let sidebar = try sidebar(), model = sidebar.model
        try sidebar.click(.note("Alpha.md"))
        try sidebar.click(.note("Gamma.md"), .command)
        try sidebar.drag(.note("Gamma.md"), to: .folder("Archive"), release: false)
        XCTAssertEqual(sidebar.bridge.press?.items, [.note("Alpha.md"), .note("Gamma.md")])
        XCTAssertEqual(sidebar.bridge.press?.destination?.directory, "Archive")
        XCTAssertEqual(sidebar.bridge.selectionOverlay?.dropRows?.lowerBound, try sidebar.row(.folder("Archive")))
        XCTAssertNotNil(sidebar.bridge.dragChip?.superview)
        XCTAssertTrue(sidebar.send(.leftMouseUp, try sidebar.point(.folder("Archive")))); sidebar.settle()
        XCTAssertNil(model.errorText)
        XCTAssertNil(sidebar.bridge.dragChip)
        XCTAssertNil(sidebar.bridge.selectionOverlay?.dropRows)
        XCTAssertEqual(try model.workspace!.readNote("Archive/Alpha.md"), "# Alpha\n")
        XCTAssertEqual(try model.workspace!.readNote("Archive/Gamma.md"), "# Gamma\n")
        XCTAssertEqual(model.librarySelections, [.note("Archive/Alpha.md"), .note("Archive/Gamma.md")])
    }

    @MainActor func testDraggingUnselectedRowMovesOnlyThatRowAndKeepsOpenDocument() throws {
        let sidebar = try sidebar(), model = sidebar.model
        try sidebar.click(.note("Alpha.md"))
        try sidebar.click(.note("Beta.md"), .command)
        try sidebar.drag(.note("Delta.md"), to: .folder("Archive"))
        XCTAssertNil(model.errorText)
        XCTAssertTrue(model.libraryFiles.contains("Archive/Delta.md"))
        XCTAssertTrue(model.libraryFiles.contains("Alpha.md"))
        XCTAssertTrue(model.libraryFiles.contains("Beta.md"))
    }

    @MainActor func testUselessAndCancelledDropsLeaveEverythingInPlace() throws {
        let sidebar = try sidebar(), model = sidebar.model
        // Onto a sibling: the destination is the notebook the document is already in.
        try sidebar.drag(.note("Alpha.md"), to: .note("Gamma.md"), release: false)
        XCTAssertNotNil(sidebar.bridge.press?.items)
        XCTAssertNil(sidebar.bridge.press?.destination)
        XCTAssertNil(sidebar.bridge.selectionOverlay?.dropRows)
        XCTAssertTrue(sidebar.send(.leftMouseUp, try sidebar.point(.note("Gamma.md")))); sidebar.settle()
        // A folder cannot land inside itself.
        try sidebar.drag(.folder("Archive"), to: .folder("Archive"), release: false)
        XCTAssertNil(sidebar.bridge.press?.destination)
        XCTAssertTrue(sidebar.send(.leftMouseUp, try sidebar.point(.folder("Archive")))); sidebar.settle()
        // Escape ends a drag over a valid destination.
        try sidebar.drag(.note("Alpha.md"), to: .folder("Archive"), release: false)
        XCTAssertEqual(sidebar.bridge.press?.destination?.directory, "Archive")
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: sidebar.window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        XCTAssertNil(sidebar.bridge.handlePointer(escape))
        XCTAssertNil(sidebar.bridge.press); XCTAssertNil(sidebar.bridge.dragChip)
        XCTAssertFalse(sidebar.send(.leftMouseUp, try sidebar.point(.folder("Archive"))))
        XCTAssertNil(model.errorText)
        XCTAssertTrue(model.libraryFiles.contains("Alpha.md"))
        XCTAssertFalse(model.libraryFiles.contains("Archive/Alpha.md"))
        XCTAssertTrue(model.folders.contains("Archive"))
    }

    @MainActor func testDroppingOnDocumentInsideFolderTargetsThatFolder() throws {
        let sidebar = try sidebar(), model = sidebar.model
        sidebar.model.libraryExpandRequest = .folder("Archive"); sidebar.settle()
        try sidebar.drag(.note("Beta.md"), to: .note("Archive/Old.md"), release: false)
        let destination = try XCTUnwrap(sidebar.bridge.press?.destination)
        XCTAssertEqual(destination.directory, "Archive")
        XCTAssertEqual(destination.rows.lowerBound, try sidebar.row(.folder("Archive")))
        XCTAssertGreaterThanOrEqual(destination.rows.upperBound, try sidebar.row(.note("Archive/Old.md")))
        XCTAssertTrue(sidebar.send(.leftMouseUp, try sidebar.point(.note("Archive/Old.md")))); sidebar.settle()
        XCTAssertNil(model.errorText)
        XCTAssertTrue(model.libraryFiles.contains("Archive/Beta.md"))
    }

    @MainActor func testDraggingBesideNamesSweepsSelectionThatThenMovesTogether() throws {
        let sidebar = try sidebar(), model = sidebar.model
        try sidebar.click(.note("Gamma.md"))
        let start = try sidebar.blank(.note("Alpha.md")), end = try sidebar.blank(.note("Delta.md"))
        XCTAssertTrue(sidebar.send(.leftMouseDown, start))
        XCTAssertTrue(sidebar.send(.leftMouseDragged, NSPoint(x: start.x - 20, y: (start.y + end.y) / 2)))
        sidebar.bridge.dragTimer?.invalidate()
        XCTAssertNotNil(sidebar.bridge.selectionOverlay?.marquee)
        XCTAssertNil(sidebar.bridge.dragChip)
        XCTAssertTrue(sidebar.send(.leftMouseDragged, end))
        XCTAssertTrue(sidebar.send(.leftMouseUp, end)); sidebar.settle()
        XCTAssertNil(sidebar.bridge.selectionOverlay?.marquee)
        XCTAssertEqual(model.librarySelections, [.note("Alpha.md"), .note("Beta.md"), .note("Delta.md")])
        XCTAssertTrue(model.libraryFiles.contains("Alpha.md"))
        // Sweeping back shrinks the selection.
        XCTAssertTrue(sidebar.send(.leftMouseDown, start))
        XCTAssertTrue(sidebar.send(.leftMouseDragged, end)); sidebar.bridge.dragTimer?.invalidate()
        XCTAssertTrue(sidebar.send(.leftMouseDragged, try sidebar.blank(.note("Beta.md"))))
        XCTAssertTrue(sidebar.send(.leftMouseUp, try sidebar.blank(.note("Beta.md")))); sidebar.settle()
        XCTAssertEqual(model.librarySelections, [.note("Alpha.md"), .note("Beta.md")])
        try sidebar.drag(.note("Beta.md"), to: .folder("Archive"))
        XCTAssertNil(model.errorText)
        XCTAssertTrue(model.libraryFiles.contains("Archive/Alpha.md"))
        XCTAssertTrue(model.libraryFiles.contains("Archive/Beta.md"))
        XCTAssertTrue(model.libraryFiles.contains("Delta.md"))
    }

    @MainActor func testClickBesideNameStillSelects() throws {
        let sidebar = try sidebar()
        let location = try sidebar.blank(.note("Delta.md"))
        XCTAssertTrue(sidebar.send(.leftMouseDown, location)); XCTAssertTrue(sidebar.send(.leftMouseUp, location)); sidebar.settle()
        XCTAssertEqual(sidebar.model.selectedNote, "Delta.md")
    }

    @MainActor func testNotebookHeaderClickOpensNotebook() throws {
        let sidebar = try sidebar(), model = sidebar.model
        try sidebar.click(.note("Beta.md"))
        try sidebar.click(.notebook("derecho"))
        XCTAssertNil(model.selectedNote)
        XCTAssertEqual(model.librarySelections, [.notebook("derecho")])
    }

    /// Set NOTES_SIDEBAR_DRAG_SCREENSHOT to a PNG path to inspect a drag in progress.
    @MainActor func testDragInProgressScreenshot() throws {
        guard let path = ProcessInfo.processInfo.environment["NOTES_SIDEBAR_DRAG_SCREENSHOT"] else { throw XCTSkip("Set NOTES_SIDEBAR_DRAG_SCREENSHOT to render the sidebar.") }
        let sidebar = try sidebar()
        sidebar.model.libraryExpandRequest = .folder("Archive"); sidebar.settle()
        try sidebar.click(.note("Alpha.md"))
        try sidebar.click(.note("Gamma.md"), .command)
        // The drag timer follows the real pointer, which is not over this window.
        sidebar.bridge.dragTimer?.invalidate()
        try sidebar.drag(.note("Gamma.md"), to: .note("Archive/Old.md"), release: false)
        sidebar.bridge.dragTimer?.invalidate()
        sidebar.settle()
        let view = try XCTUnwrap(sidebar.window.contentView)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width) * 2, pixelsHigh: Int(view.bounds.height) * 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap)).cgContext
        context.setFillColor(NSColor.windowBackgroundColor.cgColor); context.fill(CGRect(x: 0, y: 0, width: bitmap.pixelsWide, height: bitmap.pixelsHigh))
        context.scaleBy(x: 2, y: 2)
        if view.isFlipped { context.translateBy(x: 0, y: view.bounds.height); context.scaleBy(x: 1, y: -1) }
        try XCTUnwrap(view.layer).render(in: context)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
        let chip = try XCTUnwrap(sidebar.bridge.dragChip)
        XCTAssertTrue(chip.frame.intersects(view.bounds))
        let chipBitmap = try XCTUnwrap(chip.bitmapImageRepForCachingDisplay(in: chip.bounds))
        chip.cacheDisplay(in: chip.bounds, to: chipBitmap)
        try XCTUnwrap(chipBitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path + ".chip.png"))
        sidebar.bridge.cancelPointer()
    }
}
