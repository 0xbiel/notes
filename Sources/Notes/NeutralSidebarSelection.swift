import SwiftUI
import AppKit

/// Draw selection on the entire native row, including the disclosure arrow.
/// The native table still owns keyboard navigation and accessibility selection.
struct NeutralSidebarSelection: NSViewRepresentable {
    @AppStorage("notes.accent") private var accent = ""
    func makeNSView(context: Context) -> SelectionBridge { SelectionBridge() }
    func updateNSView(_ view: SelectionBridge, context: Context) {
        view.accent = NSColor(NotebookAccent.color(accent))
        DispatchQueue.main.async { [weak view] in view?.connect() }
    }
    static func dismantleNSView(_ view: SelectionBridge, coordinator: ()) { view.disconnect() }

    final class SelectionBridge: NSView {
        var accent = NSColor.controlAccentColor
        private weak var table: NSTableView?
        private var monitor: Any?
        private var observers: [NSObjectProtocol] = []
        private var sidebarFocused = false
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
                for name in [NSTableView.selectionDidChangeNotification, NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                    observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.refresh() }
                    })
                }
            }
            refresh()
        }
        private func refresh() {
            guard let table else { return }
            let range = table.rows(in: table.visibleRect)
            guard range.location != NSNotFound else { return }
            let focused = sidebarFocused && table.window?.isKeyWindow == true
            for index in range.location..<min(NSMaxRange(range), table.numberOfRows) {
                guard let row = table.rowView(atRow: index, makeIfNecessary: false) else { continue }
                row.wantsLayer = true; row.layer?.cornerRadius = 7
                row.backgroundColor = table.isRowSelected(index) ? (focused ? accent.withAlphaComponent(0.28) : NSColor.labelColor.withAlphaComponent(0.09)) : .clear
                row.needsDisplay = true
            }
        }
        func disconnect() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            monitor = nil; observers = []; table = nil
        }
    }
}
