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
        private weak var table: NSTableView?
        private var monitor: Any?
        private var observers: [NSObjectProtocol] = []
        private var sidebarFocused = false
        private var selectionOverlay: SelectionOverlay?
        private var pointerMonitor: Any?
        private var pointer = NotebookPointerReorder()
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
                            if name == NSWindow.didResignKeyNotification { self?.pointer.cancel(); self?.selectionOverlay?.insertionY = nil }
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
        private func handlePointer(_ event: NSEvent) -> NSEvent? {
            guard let outline = table as? NSOutlineView, let model else { return event }
            let point = outline.convert(event.locationInWindow, from: nil)
            let roots = (0..<outline.numberOfRows).filter { outline.level(forRow: $0) == 0 }
            let ids = model.activeNotebooks.map(\.id)
            guard roots.count == ids.count else { pointer.cancel(); selectionOverlay?.insertionY = nil; return event }
            let headers = zip(ids, roots).map { NotebookPointerReorder.Header(id: $0.0, rect: outline.rect(ofRow: $0.1), subtreeEnd: outline.rect(ofRow: outline.numberOfRows - 1).maxY) }
            if event.type == .leftMouseDown {
                guard event.modifierFlags.intersection([.control, .command, .shift]).isEmpty, event.window === outline.window, outline.visibleRect.contains(point),
                      let header = headers.first(where: { $0.rect.contains(point) }),
                      point.x > outline.frameOfOutlineCell(atRow: roots[ids.firstIndex(of: header.id)!]).maxX + 3 else { return event }
                sidebarFocused = true
                refresh()
                pointer.begin(id: header.id, at: point)
                return nil
            }
            guard pointer.source != nil else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { pointer.cancel(); selectionOverlay?.insertionY = nil; return nil }
                return event
            }
            let inside = event.window === outline.window && outline.visibleRect.contains(point)
            pointer.move(to: point, headers: headers, inside: inside)
            selectionOverlay?.insertionY = pointer.insertionY
            selectionOverlay?.lineColor = accent
            if event.type == .leftMouseDragged {
                outline.autoscroll(with: event)
                return nil
            }
            if event.type == .leftMouseUp {
                let result = pointer.finish()
                selectionOverlay?.insertionY = nil
                switch result {
                case .click(let id): model.openNotebook(id)
                case .move(let id, let target, let after): model.reorderNotebook(id, relativeTo: target, after: after)
                case nil: break
                }
                return nil
            }
            return event
        }
        private func refresh() {
            guard let table else { return }
            if table.selectionHighlightStyle != .none { table.selectionHighlightStyle = .none }
            guard let overlay = selectionOverlay else { return }
            // One stable drawing surface survives native row reuse and live resizing.
            // Avoid assigning animated row backgrounds after every SwiftUI layout.
            overlay.frame = table.bounds
            overlay.selectionColor = sidebarFocused && table.window?.isKeyWindow == true
                ? accent.withAlphaComponent(0.28) : NSColor.labelColor.withAlphaComponent(0.09)
            overlay.needsDisplay = true
        }
        func disconnect() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }
            pointerMonitor = nil
            pointer.cancel()
            selectionOverlay?.removeFromSuperview(); selectionOverlay = nil
            monitor = nil; observers = []; table = nil
        }
    }
    final class SelectionOverlay: NSView {
        weak var table: NSTableView?
        var insertionY: CGFloat? { didSet { needsDisplay = true } }
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
            selectionColor.setFill()
            for index in table.selectedRowIndexes where index < table.numberOfRows {
                let rect = selectionRect(forRow: index)
                if rect.intersects(dirtyRect) { NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill() }
            }
        }
    }

}
