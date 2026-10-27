import SwiftUI
import AppKit

/// Draw selection on the entire native row, including the disclosure arrow.
/// The native table still owns keyboard navigation and accessibility selection.
struct NeutralSidebarSelection: NSViewRepresentable {
    var model: Workbench? = nil
    @AppStorage("notes.accent") private var accent = ""
    func makeNSView(context: Context) -> SelectionBridge { SelectionBridge() }
    func updateNSView(_ view: SelectionBridge, context: Context) {
        view.model = model
        view.accent = NSColor(NotebookAccent.color(accent))
        view.connect()
        if view.window == nil { DispatchQueue.main.async { [weak view] in view?.connect() } }
    }
    static func dismantleNSView(_ view: SelectionBridge, coordinator: ()) { view.disconnect() }

    final class SelectionBridge: NSView {
        weak var model: Workbench?
        var accent = NSColor.controlAccentColor
        private(set) weak var table: NSTableView?
        private var monitor: Any?
        private var observers: [NSObjectProtocol] = []
        var sidebarFocused = false
        private(set) var selectionOverlay: SelectionOverlay?
        private var pointerMonitor: Any?
        private var styleObservation: NSKeyValueObservation?
        // Pointer state, driven by the library pointer extension.
        var pointer = NotebookPointerReorder()
        var press: LibraryPointerPress?
        var anchorRow: Int?
        var dragChip: NSView?
        var dragTimer: Timer?
        var lastDrag: NSEvent?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); connect() }
        func connect() {
            if table == nil {
                func tables(in root: NSView) -> [NSTableView] {
                    if let table = root as? NSTableView { return [table] }
                    return root.subviews.flatMap { tables(in: $0) }
                }
                var parent = superview
                while let container = parent {
                    if let found = tables(in: container).first { table = found; break }
                    parent = container.superview
                }
            }
            guard let table else { return }
            table.selectionHighlightStyle = .none
            if styleObservation == nil {
                // SwiftUI restores the native source-list highlight when it re-renders the List
                // (hovering any control triggers that), which flashes over our overlay.
                styleObservation = table.observe(\.selectionHighlightStyle) { table, _ in
                    if table.selectionHighlightStyle != .none { table.selectionHighlightStyle = .none }
                }
            }
            if let outline = table as? NSOutlineView {
                outline.indentationPerLevel = 18
                outline.indentationMarkerFollowsCell = true
            }
            if selectionOverlay?.superview !== table {
                selectionOverlay?.removeFromSuperview()
                let overlay = SelectionOverlay(table: table)
                overlay.frame = table.bounds
                overlay.autoresizingMask = [.width, .height]
                table.addSubview(overlay, positioned: .below, relativeTo: nil)
                selectionOverlay = overlay
                table.postsFrameChangedNotifications = true
                table.enclosingScrollView?.contentView.postsBoundsChangedNotifications = true
            }
            if monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown, .scrollWheel]) { [weak self] event in
                    MainActor.assumeIsolated {
                        guard let self, let table = self.table else { return }
                        if event.type == .leftMouseDown || event.type == .rightMouseDown {
                            self.sidebarFocused = event.window === table.window && table.visibleRect.contains(table.convert(event.locationInWindow, from: nil))
                        }
                        let keyboard = event.type == .keyDown
                        DispatchQueue.main.async { [weak self] in
                            if keyboard, let self, let table = self.table, let responder = table.window?.firstResponder as? NSView {
                                self.sidebarFocused = responder === table || responder.isDescendant(of: table)
                            }
                            self?.refresh()
                        }
                    }
                    return event
                }
                let watched: [(Notification.Name, AnyObject?)] = [
                    (NSTableView.selectionDidChangeNotification, table),
                    (NSOutlineView.selectionDidChangeNotification, table),
                    (NSWindow.didBecomeKeyNotification, table.window),
                    (NSWindow.didResignKeyNotification, table.window),
                    (NSWindow.didResizeNotification, table.window),
                    (NSView.frameDidChangeNotification, table),
                    (NSView.boundsDidChangeNotification, table.enclosingScrollView?.contentView)
                ]
                for (name, object) in watched where object != nil {
                    observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated {
                            if name == NSWindow.didResignKeyNotification { self?.cancelPointer() }
                            self?.refresh()
                        }
                    })
                }
            }
            if pointerMonitor == nil, model != nil {
                pointerMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown]) { [weak self] event in
                    let consumed = MainActor.assumeIsolated { self?.handlePointer(event) == nil }
                    return consumed ? nil : event
                }
            }
            refresh()
        }
        func refresh() {
            guard let table else { return }
            if table.selectionHighlightStyle != .none { table.selectionHighlightStyle = .none }
            guard let overlay = selectionOverlay else { return }
            // One stable drawing surface survives native row reuse and live resizing.
            // Avoid assigning animated row backgrounds after every SwiftUI layout.
            overlay.frame = table.bounds
            overlay.lineColor = accent
            overlay.selectionColor = sidebarFocused && table.window?.isKeyWindow == true
                ? accent.withAlphaComponent(0.28) : NSColor(name: nil) { appearance in
                    // Matches the system's neutral source-list selection grey in each appearance.
                    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                        ? NSColor.labelColor.withAlphaComponent(0.09) : NSColor.black.withAlphaComponent(0.13)
                }
            overlay.needsDisplay = true
        }
        func disconnect() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }
            pointerMonitor = nil
            cancelPointer()
            selectionOverlay?.removeFromSuperview(); selectionOverlay = nil
            styleObservation = nil
            monitor = nil; observers = []; table = nil
        }
    }
    final class SelectionOverlay: NSView {
        weak var table: NSTableView?
        var insertionY: CGFloat? { didSet { needsDisplay = true } }
        /// The row under a press that is not selected yet.
        var pressedRow: Int? { didSet { if pressedRow != oldValue { needsDisplay = true } } }
        /// The folder or notebook rows that would receive the dragged items.
        /// The rectangle swept while selecting rows by dragging.
        var marquee: NSRect? { didSet { if marquee != oldValue { needsDisplay = true } } }
        var dropRows: ClosedRange<Int>? { didSet { if dropRows != oldValue { needsDisplay = true } } }
        var lineColor = NSColor.controlAccentColor
        var selectionColor = NSColor.labelColor.withAlphaComponent(0.09)
        init(table: NSTableView) { self.table = table; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        func selectionRect(forRow index: Int) -> NSRect {
            guard let table else { return .zero }
            return convert(table.rect(ofRow: index), from: table).insetBy(dx: 8, dy: 1)
        }
        override func draw(_ dirtyRect: NSRect) {
            guard let table else { return }
            if let y = insertionY {
                lineColor.setFill()
                NSBezierPath(roundedRect: NSRect(x: 8, y: y - 1, width: max(0, bounds.width - 16), height: 2), xRadius: 1, yRadius: 1).fill()
            }
            if let rows = dropRows, rows.upperBound < table.numberOfRows {
                let rect = selectionRect(forRow: rows.lowerBound).union(selectionRect(forRow: rows.upperBound))
                lineColor.withAlphaComponent(0.1).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
                lineColor.withAlphaComponent(0.7).setStroke()
                let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: 6.25, yRadius: 6.25)
                border.lineWidth = 1.5; border.stroke()
            }
            if let row = pressedRow, row < table.numberOfRows, !table.isRowSelected(row) {
                NSColor.labelColor.withAlphaComponent(0.07).setFill()
                NSBezierPath(roundedRect: selectionRect(forRow: row), xRadius: 7, yRadius: 7).fill()
            }
            selectionColor.setFill()
            for index in table.selectedRowIndexes where index < table.numberOfRows {
                let rect = selectionRect(forRow: index)
                if rect.intersects(dirtyRect) { NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill() }
            }
            if let marquee {
                let rect = convert(marquee, from: table).insetBy(dx: 0.5, dy: 0.5)
                lineColor.withAlphaComponent(0.1).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
                lineColor.withAlphaComponent(0.55).setStroke()
                NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).stroke()
            }
        }
    }

}
