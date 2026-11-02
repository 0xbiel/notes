import SwiftUI
import AppKit

/// Uses the same window coordinates as the sidebar's pointer drag. No file move or import occurs.
struct DocumentPaneDropSurface: NSViewRepresentable {
    let model: Workbench
    let documentID: String
    let enabled: Bool
    func makeNSView(context: Context) -> Surface { Surface() }
    func updateNSView(_ view: Surface, context: Context) {
        view.model = model; view.documentID = documentID; view.enabled = enabled
    }

    final class Entry { weak var view: Surface?; init(_ view: Surface) { self.view = view } }
    @MainActor private static var entries: [Entry] = []
    @MainActor static func target(at point: NSPoint, in window: NSWindow, model: Workbench) -> DocumentPaneDropTarget? {
        guard model.selectedLibraryPath != nil, !model.showPreferences, !model.showOnboarding else { return nil }
        entries.removeAll { $0.view == nil }
        for view in entries.compactMap(\.view) where view.model === model && view.window === window && view.enabled && !view.isHiddenOrHasHiddenAncestor {
            let local = view.convert(point, from: nil)
            if view.visibleRect.intersection(view.bounds).contains(local), let edge = DocumentPaneEdge.resolve(at: local, size: view.bounds.size) {
                return .init(paneID: view.documentID, edge: edge)
            }
        }
        return nil
    }

    final class Surface: NSView {
        weak var model: Workbench?
        var documentID = ""
        var enabled = false
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil, !DocumentPaneDropSurface.entries.contains(where: { $0.view === self }) {
                DocumentPaneDropSurface.entries.append(Entry(self))
            }
        }
    }
}

/// A dedicated grip avoids a menu or the title bar's window-drag behavior taking the gesture.
struct DocumentPaneGrip: NSViewRepresentable {
    let model: Workbench
    let documentID: String
    func makeNSView(context: Context) -> Grip { Grip() }
    func updateNSView(_ view: Grip, context: Context) { view.model = model; view.documentID = documentID }

    final class Grip: NSView {
        weak var model: Workbench?
        var documentID = ""
        private var origin: NSPoint?
        private var dragging = false
        override var acceptsFirstResponder: Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override init(frame: NSRect) {
            super.init(frame: frame)
            setAccessibilityElement(true); setAccessibilityRole(.button)
            setAccessibilityIdentifier("workspace.paneHandle")
            setAccessibilityLabel(DocumentWorkspaceText.value("Move pane", "Mover panel"))
            toolTip = DocumentWorkspaceText.value("Drag to move this pane", "Arrastra para mover este panel")
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.secondaryLabelColor.setFill()
            for row in 0..<2 { for column in 0..<3 {
                NSBezierPath(ovalIn: NSRect(x: bounds.midX - 6 + CGFloat(column) * 5, y: bounds.midY - 3.5 + CGFloat(row) * 5, width: 2, height: 2)).fill()
            } }
        }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
        override func mouseDown(with event: NSEvent) {
            guard event.window === window else { return }
            origin = event.locationInWindow; dragging = false
            model?.selectWorkspaceTab(documentID)
            window?.makeFirstResponder(self)
        }
        override func mouseDragged(with event: NSEvent) {
            guard let origin, let window, event.window === window,
                  dragging || hypot(event.locationInWindow.x - origin.x, event.locationInWindow.y - origin.y) >= 4 else { return }
            dragging = true; NSCursor.closedHand.set()
            model?.previewDocumentDrop(at: event.locationInWindow, in: window, moving: documentID)
        }
        override func mouseUp(with event: NSEvent) {
            defer { cancelDrag() }
            guard dragging, let window, event.window === window, let model else { return }
            model.previewDocumentDrop(at: event.locationInWindow, in: window, moving: documentID)
            if let target = model.documentDropPreview { model.moveWorkspacePane(documentID, to: target) }
        }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { cancelDrag() } else { super.keyDown(with: event) }
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil, dragging { cancelDrag() }
        }
        private func cancelDrag() {
            origin = nil; dragging = false; model?.documentDropPreview = nil
            NSCursor.arrow.set()
        }
    }
}

struct DocumentPaneDropHighlight: View {
    let edge: DocumentPaneEdge
    @AppStorage("notes.accent") private var accent = ""
    var body: some View {
        GeometryReader { geometry in
            let rect = edge.frame(in: geometry.size)
            RoundedRectangle(cornerRadius: 9).fill(NotebookAccent.color(accent).opacity(0.16))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(NotebookAccent.color(accent).opacity(0.8), lineWidth: 2))
                .frame(width: max(0, rect.width), height: max(0, rect.height)).offset(x: rect.minX, y: rect.minY)
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

/// Consume Command-W before the standard macOS Close Window menu item can close the workspace.
struct DocumentPaneCloseShortcut: NSViewRepresentable {
    let model: Workbench
    func makeNSView(context: Context) -> Bridge { Bridge(model: model) }
    func updateNSView(_ view: Bridge, context: Context) { view.model = model }
    final class Bridge: NSView {
        weak var model: Workbench?
        nonisolated(unsafe) private var monitor: Any?
        init(model: Workbench) { self.model = model; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = MainActor.assumeIsolated { self?.handleCloseEvent(event) ?? false }
                return handled ? nil : event
            }
        }
        func handleCloseEvent(_ event: NSEvent) -> Bool {
            guard event.type == .keyDown, event.window === window, window?.attachedSheet == nil,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]) == [.command],
                  event.charactersIgnoringModifiers?.lowercased() == "w", let model,
                  !model.showPreferences, !model.showQuickOpen, !model.showOnboarding, model.selectedLibraryPath != nil,
                  let id = model.documentWorkspace.focusedID else { return false }
            model.closeWorkspaceTab(id)
            return true
        }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
