import XCTest
import AppKit
import SwiftUI
import PDFKit
import LectureCore
@testable import Notes

final class DocumentWorkspaceTests: XCTestCase {
    func testDropsResolveEveryEdgeAndCenterInWideAndTallPanes() {
        for size in [CGSize(width: 1000, height: 300), CGSize(width: 300, height: 1000)] {
            XCTAssertEqual(DocumentPaneEdge.resolve(at: CGPoint(x: 4, y: size.height / 2), size: size), .left)
            XCTAssertEqual(DocumentPaneEdge.resolve(at: CGPoint(x: size.width - 4, y: size.height / 2), size: size), .right)
            XCTAssertEqual(DocumentPaneEdge.resolve(at: CGPoint(x: size.width / 2, y: 4), size: size), .top)
            XCTAssertEqual(DocumentPaneEdge.resolve(at: CGPoint(x: size.width / 2, y: size.height - 4), size: size), .bottom)
            XCTAssertEqual(DocumentPaneEdge.resolve(at: CGPoint(x: size.width / 2, y: size.height / 2), size: size), .center)
            XCTAssertNil(DocumentPaneEdge.resolve(at: CGPoint(x: -1, y: 10), size: size))
        }
    }

    func testMovingPanesToEverySidePreservesIDsAndRemovesEmptySplits() throws {
        for edge in DocumentPaneEdge.allCases {
            var state = DocumentWorkspace()
            state.open("First.md")
            let first = try XCTUnwrap(state.focusedID)
            state.split(path: "Reference.pdf", axis: .horizontal)
            let pdf = try XCTUnwrap(state.focusedID)
            state.split(path: "Second.md", axis: .vertical)
            let second = try XCTUnwrap(state.focusedID)
            state.move(first, to: .init(paneID: second, edge: edge))
            XCTAssertEqual(state.documents.count, 3)
            XCTAssertEqual(Set(state.visibleIDs), Set([first, pdf, second]))
            XCTAssertEqual(state.focusedID, first)
            XCTAssertTrue(state.isValid)
            let frames = DocumentPaneFrames(root: state.root, bounds: CGRect(x: 0, y: 0, width: 1000, height: 800))
            let a = try XCTUnwrap(frames.panes[first]), b = try XCTUnwrap(frames.panes[second])
            switch edge {
            case .left: XCTAssertLessThan(a.maxX, b.minX)
            case .right: XCTAssertGreaterThan(a.minX, b.maxX)
            case .top: XCTAssertLessThan(a.maxY, b.minY)
            case .bottom: XCTAssertGreaterThan(a.minY, b.maxY)
            case .center: XCTAssertEqual(state.visibleIDs, [second, pdf, first])
            }
            let before = state
            state.move(first, to: .init(paneID: first, edge: edge))
            XCTAssertEqual(state, before)
        }
    }

    @MainActor func testSidebarEdgeDropsGripMoveAndCommandWUseNativeViews() async throws {
        _ = NSApplication.shared
        let (model, _) = try fixture()
        model.openNote("First.md")
        let first = try XCTUnwrap(model.documentWorkspace.focusedID)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1260, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: HStack(spacing: 0) {
            CourseSidebar(model: model).frame(width: 260)
            DocumentWorkspaceView(model: model)
        }.frame(width: 1260, height: 760))
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -6000, y: -6000)); window.orderFrontRegardless()
        defer { window.orderOut(nil); window.close() }
        func settle() async throws { try await Task.sleep(for: .milliseconds(200)); host.layoutSubtreeIfNeeded() }
        func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
            (view as? T).map { [$0] } ?? view.subviews.flatMap { find(type, in: $0) }
        }
        func mouse(_ type: NSEvent.EventType, _ point: NSPoint) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        try await settle()
        let outline = try XCTUnwrap(find(NSOutlineView.self, in: host).first)
        let bridge = try XCTUnwrap(find(NeutralSidebarSelection.SelectionBridge.self, in: host).first)
        bridge.connect(); try await settle()
        func surface(_ id: String) throws -> DocumentPaneDropSurface.Surface {
            try XCTUnwrap(find(DocumentPaneDropSurface.Surface.self, in: host).first { $0.documentID == id })
        }
        func dragLibrary(_ path: String, to point: NSPoint, edge: DocumentPaneEdge) throws {
            let row = try XCTUnwrap(LibraryRowMarker.items(in: outline).first { $0.value == .note(path) }?.key)
            let labelEnd = try XCTUnwrap(LibraryRowMarker.labelEnd(row: row, in: outline))
            let start = outline.convert(NSPoint(x: labelEnd - 12, y: outline.rect(ofRow: row).midY), to: nil)
            XCTAssertNil(bridge.handlePointer(try mouse(.leftMouseDown, start)))
            XCTAssertNil(bridge.handlePointer(try mouse(.leftMouseDragged, point)))
            XCTAssertEqual(model.documentDropPreview?.edge, edge)
            XCTAssertNil(bridge.handlePointer(try mouse(.leftMouseUp, point)))
            XCTAssertNil(model.documentDropPreview)
        }
        var target = try surface(first)
        try dragLibrary("Reference.pdf", to: target.convert(NSPoint(x: 12, y: target.bounds.midY), to: nil), edge: .left)
        let pdf = try XCTUnwrap(model.documentWorkspace.focusedID)
        XCTAssertEqual(model.documentWorkspace.visibleIDs, [pdf, first])
        XCTAssertEqual(model.selectedFile, "Reference.pdf")
        try await settle()
        target = try surface(first)
        try dragLibrary("Second.md", to: target.convert(NSPoint(x: target.bounds.midX, y: target.bounds.height - 12), to: nil), edge: .bottom)
        let second = try XCTUnwrap(model.documentWorkspace.focusedID)
        XCTAssertEqual(model.documentWorkspace.visibleIDs, [pdf, first, second])
        XCTAssertEqual(try model.workspace?.readNote("Second.md"), "# Second\n")
        XCTAssertTrue(model.libraryFiles.contains("Reference.pdf"), "Opening a split must not move library files")
        try await settle()
        let grip = try XCTUnwrap(find(DocumentPaneGrip.Grip.self, in: host).first { $0.documentID == pdf })
        let gripPoint = grip.convert(NSPoint(x: grip.bounds.midX, y: grip.bounds.midY), to: nil)
        let gripHit = (window.contentView?.superview ?? window.contentView)?.hitTest(gripPoint)
        XCTAssertTrue(gripHit === grip, "The six dots must receive the pointer instead of a menu or window-drag overlay")
        target = try surface(first)
        let end = target.convert(NSPoint(x: target.bounds.midX, y: 10), to: nil)
        grip.mouseDown(with: try mouse(.leftMouseDown, gripPoint))
        grip.mouseDragged(with: try mouse(.leftMouseDragged, end))
        XCTAssertEqual(model.documentDropPreview, .init(paneID: first, edge: .top))
        grip.mouseUp(with: try mouse(.leftMouseUp, end))
        XCTAssertNil(model.documentDropPreview)
        XCTAssertEqual(model.documentWorkspace.documents.count, 3)
        XCTAssertTrue(model.documentWorkspace.isValid)
        try await settle()
        XCTAssertTrue(find(DocumentPaneGrip.Grip.self, in: host).first { $0.documentID == pdf } === grip)
        let frames = DocumentPaneFrames(root: model.documentWorkspace.root, bounds: CGRect(x: 0, y: 0, width: 1000, height: 760))
        XCTAssertLessThan(try XCTUnwrap(frames.panes[pdf]).maxY, try XCTUnwrap(frames.panes[first]).minY)
        let keyboard = try XCTUnwrap(find(DocumentPaneCloseShortcut.Bridge.self, in: host).first)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))
        XCTAssertTrue(keyboard.handleCloseEvent(event))
        XCTAssertFalse(model.documentWorkspace.documents.contains { $0.id == pdf })
        XCTAssertEqual(model.documentWorkspace.visibleIDs.count, 2)
        XCTAssertNotNil(window.contentView, "Closing a pane must leave the window open")
        XCTAssertNil(model.errorText)
    }

    func testOpeningTabsReplacesOnlyFocusedPaneAndReusesVisibleDocuments() throws {
        var state = DocumentWorkspace()
        state.open("Note.md")
        let note = try XCTUnwrap(state.focusedID)
        state.split(path: "Reference.pdf", axis: .horizontal)
        let pdf = try XCTUnwrap(state.focusedID)
        state.open("Second.md")
        let second = try XCTUnwrap(state.focusedID)
        XCTAssertEqual(state.visibleIDs, [note, second])
        XCTAssertEqual(state.documents.count, 3)
        state.open("Note.md")
        XCTAssertEqual(state.focusedID, note)
        XCTAssertEqual(state.visibleIDs, [note, second])
        state.select(pdf)
        XCTAssertEqual(state.visibleIDs, [pdf, second])
        XCTAssertTrue(state.isValid)
    }

    func testNestedSplitsSwapExpandAndClosePreserveOtherTabs() throws {
        var state = DocumentWorkspace()
        state.open("Note.md")
        let note = try XCTUnwrap(state.focusedID)
        state.setMode("edit")
        state.split(path: "Reference.pdf", axis: .vertical, before: true)
        let pdf = try XCTUnwrap(state.focusedID)
        state.split(path: "Other.md", axis: .horizontal)
        let other = try XCTUnwrap(state.focusedID), original = state.root
        XCTAssertEqual(state.visibleIDs, [pdf, other, note])
        state.toggleExpanded(pdf)
        XCTAssertEqual(state.expandedID, pdf)
        XCTAssertEqual(state.root, original)
        state.toggleExpanded(pdf)
        XCTAssertNil(state.expandedID)
        state.swap(pdf, note)
        XCTAssertEqual(state.visibleIDs, [note, other, pdf])
        state.close(other)
        XCTAssertEqual(state.visibleIDs, [note, pdf])
        state.close(pdf)
        XCTAssertEqual(state.root, .pane(note))
        XCTAssertEqual(state.focused?.mode, "edit")
        state.close(note)
        XCTAssertTrue(state.documents.isEmpty)
        XCTAssertTrue(state.isValid)
    }

    func testHiddenTabsSurviveClosingLastPaneAndModesAreIndependent() throws {
        var state = DocumentWorkspace()
        state.open("First.md")
        let first = try XCTUnwrap(state.focusedID)
        state.setMode("edit")
        state.split(axis: .horizontal)
        let duplicate = try XCTUnwrap(state.focusedID)
        state.setMode("preview")
        XCTAssertEqual(state.documents.first { $0.id == first }?.mode, "edit")
        state.open("Other.md")
        let other = try XCTUnwrap(state.focusedID)
        state.close(first); state.close(other)
        XCTAssertEqual(state.root, .pane(duplicate))
        XCTAssertEqual(state.focused?.path, "First.md")
        XCTAssertEqual(state.focused?.mode, "preview")
        XCTAssertTrue(state.isValid)
    }

    func testRestorationResizingAndPruningStaleFiles() throws {
        var state = DocumentWorkspace()
        state.open("Folder/A.md")
        state.split(path: "Folder/B.pdf", axis: .vertical)
        guard case .split(let id, _, _, _, _) = state.root else { return XCTFail("Missing split") }
        state.root = state.root?.resizing(id, fraction: 0.7)
        state.toggleExpanded(try XCTUnwrap(state.focusedID))
        let decoded = try JSONDecoder().decode(DocumentWorkspace.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded, state)
        state.remapPaths { $0.replacingOccurrences(of: "Folder/", with: "Renamed/") }
        state.retainPaths(["Renamed/A.md"])
        XCTAssertEqual(state.focused?.path, "Renamed/A.md")
        XCTAssertNil(state.expandedID)
        XCTAssertTrue(state.isValid)
        var invalid = state
        invalid.root = .split(id: "invalid", axis: .horizontal, fraction: 0.5, first: state.root!, second: state.root!)
        XCTAssertFalse(invalid.isValid)
    }

    func testPaneFramesCoverNestedLayoutWithoutOverlap() throws {
        let root = DocumentPaneLayout.split(id: "outer", axis: .horizontal, fraction: 0.6,
            first: .pane("a"), second: .split(id: "inner", axis: .vertical, fraction: 0.4, first: .pane("b"), second: .pane("c")))
        let frames = DocumentPaneFrames(root: root, bounds: CGRect(x: 0, y: 0, width: 1000, height: 800))
        let a = try XCTUnwrap(frames.panes["a"]), b = try XCTUnwrap(frames.panes["b"]), c = try XCTUnwrap(frames.panes["c"])
        XCTAssertEqual(a.width, 992 * 0.6, accuracy: 0.01)
        XCTAssertEqual(b.minX, a.maxX + 8, accuracy: 0.01)
        XCTAssertEqual(c.minY, b.maxY + 8, accuracy: 0.01)
        XCTAssertEqual(c.maxX, 1000, accuracy: 0.01)
        XCTAssertEqual(c.maxY, 800, accuracy: 0.01)
        XCTAssertEqual(frames.dividers.count, 2)
    }

    @MainActor private func fixture() throws -> (Workbench, URL) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".test-workspaces/Panes-" + UUID().uuidString)
        _ = try Workbench.prepareLibrary(root)
        let notebook = Notebook.copiedCourse
        try JSONEncoder().encode([notebook]).write(to: root.appendingPathComponent("session-storage/notebooks.json"))
        try Data("# First\n".utf8).write(to: root.appendingPathComponent("copied-course/First.md"))
        try Data("# Second\n".utf8).write(to: root.appendingPathComponent("copied-course/Second.md"))
        let pdf = PDFDocument()
        let image = NSImage(size: NSSize(width: 500, height: 700), flipped: false) { _ in NSColor.white.setFill(); NSBezierPath(rect: NSRect(x: 0, y: 0, width: 500, height: 700)).fill(); return true }
        pdf.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        try XCTUnwrap(pdf.dataRepresentation()).write(to: root.appendingPathComponent("copied-course/Reference.pdf"))
        let model = Workbench(workspaceRoot: root)
        XCTAssertNil(model.errorText)
        model.hideStudyComposer = true
        addTeardownBlock { @MainActor in
            model.autosaveTasks.values.forEach { $0.cancel() }
            model.media?.shutdown(); model.ai?.stop(); model.assistant?.stop(); model.maps?.shutdown()
            try? FileManager.default.removeItem(at: root)
        }
        return (model, root)
    }

    @MainActor func testNativeViewsStayMountedAcrossExpandSwapAndTabChanges() async throws {
        _ = NSApplication.shared
        let (model, _) = try fixture()
        model.openNote("First.md"); model.layout = "edit"
        let noteID = try XCTUnwrap(model.documentWorkspace.focusedID)
        model.splitWorkspace(.horizontal, path: "Reference.pdf")
        let pdfID = try XCTUnwrap(model.documentWorkspace.focusedID)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 740), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: DocumentWorkspaceView(model: model))
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -6000, y: -6000)); window.orderFrontRegardless()
        defer { window.orderOut(nil); window.close() }
        func settle() async throws { try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded() }
        func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
            (view as? T).map { [$0] } ?? view.subviews.flatMap { find(type, in: $0) }
        }
        try await settle()
        let pdf = try XCTUnwrap(find(LibraryPDFNativeView.self, in: host).first)
        let editor = try XCTUnwrap(find(MarkdownTextView.self, in: host).first)
        let controller = try XCTUnwrap(pdf.controller)
        controller.setPercentage(125)
        model.expandWorkspacePane(pdfID)
        try await settle()
        XCTAssertTrue(find(LibraryPDFNativeView.self, in: host).first === pdf)
        XCTAssertEqual(pdf.scaleFactor, 1.25, accuracy: 0.001)
        model.expandWorkspacePane(pdfID)
        model.documentWorkspace.swap(noteID, pdfID)
        try await settle()
        XCTAssertTrue(find(MarkdownTextView.self, in: host).first === editor)
        model.openNote("Second.md")
        try await settle()
        XCTAssertTrue(find(LibraryPDFNativeView.self, in: host).first === pdf)
        model.selectWorkspaceTab(pdfID)
        try await settle()
        XCTAssertTrue(find(LibraryPDFNativeView.self, in: host).first === pdf)
        XCTAssertEqual(pdf.scaleFactor, 1.25, accuracy: 0.001)
        model.selectWorkspaceTab(noteID)
        model.hideStudyComposer = false
        try await settle()
        let observers = find(DocumentPaneFocusObserver.FocusView.self, in: host)
        func click(at point: NSPoint) throws {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            observers.forEach { $0.handleMouseEvent(event) }
        }
        model.selectWorkspaceTab(pdfID)
        try await settle()
        try click(at: editor.convert(NSPoint(x: 80, y: 25), to: nil))
        XCTAssertEqual(model.selectedNote, "First.md", "Clicking a native editor must activate its pane before editing")
        let chatView = try XCTUnwrap(observers.first?.excluding.view)
        try click(at: chatView.convert(NSPoint(x: 40, y: chatView.bounds.midY), to: nil))
        XCTAssertEqual(model.selectedNote, "First.md", "Clicking the shared composer must not activate the pane underneath it")
        editor.insertText("Typed in first pane", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(model.drafts["First.md"]?.contains("Typed in first pane") == true)
        XCTAssertEqual(model.drafts["Second.md"], "# Second\n")
        if let output = ProcessInfo.processInfo.environment["NOTES_PANES_SCREENSHOT"] {
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output))
        }
        XCTAssertNil(model.errorText)
    }

    @MainActor func testDraftsRouteByPathAndTabsRestoreWithLayoutAndModes() throws {
        let (model, root) = try fixture()
        model.openNote("First.md"); model.layout = "edit"
        model.splitWorkspace(.vertical, path: "Reference.pdf", before: true)
        let pdf = try XCTUnwrap(model.documentWorkspace.focusedID)
        model.changeDraft("First edited while another pane has focus", for: "First.md")
        XCTAssertNil(model.selectedNote)
        XCTAssertEqual(model.selectedFile, "Reference.pdf")
        model.splitWorkspace(.horizontal, path: "Second.md")
        model.layout = "preview"
        model.changeDraft("Second edited", for: "Second.md")
        model.flushAutosave()
        XCTAssertEqual(try model.workspace?.readNote("First.md"), "First edited while another pane has focus")
        XCTAssertEqual(try model.workspace?.readNote("Second.md"), "Second edited")
        model.expandWorkspacePane(pdf)
        let expected = model.documentWorkspace
        let restored = Workbench(workspaceRoot: root)
        defer { restored.media?.shutdown(); restored.ai?.stop(); restored.maps?.shutdown() }
        XCTAssertNil(restored.errorText)
        XCTAssertEqual(restored.documentWorkspace, expected)
        XCTAssertEqual(restored.selectedFile, "Reference.pdf")
        XCTAssertEqual(restored.drafts["First.md"], "First edited while another pane has focus")
    }

    @MainActor func testRenameMoveAndDeletionUpdateAllOpenPanes() throws {
        let (model, _) = try fixture()
        model.openNote("First.md")
        model.splitWorkspace(.horizontal, path: "Reference.pdf")
        try model.renameLibraryFile("First.md", name: "Renamed")
        XCTAssertTrue(model.documentWorkspace.documents.contains { $0.path == "Renamed.md" })
        XCTAssertFalse(model.documentWorkspace.documents.contains { $0.path == "First.md" })
        try model.workspace?.createFolder("Folder")
        model.refreshProjectFiles([])
        model.moveLibraryItem("Reference.pdf", folder: false, into: "Folder", notebookID: "derecho")
        XCTAssertTrue(model.documentWorkspace.documents.contains { $0.path == "Folder/Reference.pdf" })
        model.deleteItem("Folder/Reference.pdf", folder: false)
        XCTAssertFalse(model.documentWorkspace.documents.contains { $0.path == "Folder/Reference.pdf" })
        XCTAssertEqual(model.selectedNote, "Renamed.md")
        XCTAssertTrue(model.documentWorkspace.isValid)
        XCTAssertNil(model.errorText)
    }

    @MainActor func testConflictedDraftCannotBeClosedAndRemainsRecoverable() throws {
        let (model, _) = try fixture()
        model.openNote("First.md")
        let id = try XCTUnwrap(model.documentWorkspace.focusedID)
        model.changeDraft("Recover this")
        try Data("External change".utf8).write(to: model.workspace!.noteURL("First.md"))
        model.closeWorkspaceTab(id)
        XCTAssertNotNil(model.errorText)
        XCTAssertEqual(model.documentWorkspace.focusedID, id)
        XCTAssertEqual(model.drafts["First.md"], "Recover this")
        XCTAssertEqual(try model.workspace?.readNote("First.md"), "External change")
    }
}
