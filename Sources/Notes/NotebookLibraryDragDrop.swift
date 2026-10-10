import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct LibraryDragPayload: Codable {
    var workspace: String
    var items: Set<NotebookSidebarSelection>
    static let type = "local.palladium.library-move"
}

struct LibraryDragSource: ViewModifier {
    @ObservedObject var model: Workbench
    let item: NotebookSidebarSelection
    func body(content: Content) -> some View {
        content.background(LibraryNativeDragSource(model: model, item: item))
    }
}

/// SwiftUI sidebar rows own their mouse selection; track a native pointer move
/// after the pointer moves, retaining the selection from mouse-down.
struct LibraryNativeDragSource: NSViewRepresentable {
    let model: Workbench
    let item: NotebookSidebarSelection
    func makeNSView(context: Context) -> Bridge { let view = Bridge(); view.model = model; view.item = item; return view }
    func updateNSView(_ view: Bridge, context: Context) { view.model = model; view.item = item }
    static func dismantleNSView(_ view: Bridge, coordinator: ()) { view.stop() }
    final class Bridge: NSView {
        weak var model: Workbench?
        var item: NotebookSidebarSelection = .note("")
        private var monitor: Any?
        private var origin: NSPoint?
        private var selection: Set<NotebookSidebarSelection> = []
        private var moving = false
        private var badge: LibraryDragBadge?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
                let consumed = MainActor.assumeIsolated { self?.handle(event) == nil }
                return consumed ? nil : event
            }
        }
        func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil; origin = nil; badge?.removeFromSuperview(); badge = nil }
        func handle(_ event: NSEvent) -> NSEvent? {
            guard let window, event.window === window, window.attachedSheet == nil, let model else { return event }
            let point = convert(event.locationInWindow, from: nil)
            if event.type == .leftMouseDown {
                origin = bounds.contains(point) && model.canManageFiles ? point : nil
                if origin != nil { selection = model.itemsForMoving(item) }
                return event
            }
            if event.type == .leftMouseUp {
                defer { origin = nil; moving = false; badge?.removeFromSuperview(); badge = nil; model.libraryDropDestination = nil; NSCursor.arrow.set() }
                guard moving else { return event }
                if let target = LibraryNativeDropArea.target(at: event.locationInWindow, window: window) {
                    model.moveLibraryItems(selection, into: target.directory, notebookID: target.notebookID)
                }
                return nil
            }
            guard let origin, moving || hypot(point.x - origin.x, point.y - origin.y) >= 5 else { return event }
            moving = true
            let target = LibraryNativeDropArea.target(at: event.locationInWindow, window: window)
            model.libraryDropDestination = target.map { $0.notebookID + ":" + $0.directory }
            NSCursor.closedHand.set()
            if badge == nil, let content = window.contentView {
                let view = LibraryDragBadge(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
                switch item {
                case .note(let path), .folder(let path): view.label = selection.count > 1 ? "\(selection.count) items" : URL(fileURLWithPath: path).lastPathComponent
                case .notebook: return event
                }
                content.addSubview(view, positioned: .above, relativeTo: nil); badge = view
            }
            if let badge, let content = window.contentView {
                let location = content.convert(event.locationInWindow, from: nil)
                badge.frame.origin = NSPoint(x: location.x + 10, y: location.y - 15)
            }
            return nil
        }
    }
}

private final class LibraryDragBadge: NSView {
    var label = ""
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.withAlphaComponent(0.94).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        (label as NSString).draw(in: bounds.insetBy(dx: 10, dy: 6), withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])
    }
}

struct LibraryNativeDropArea: NSViewRepresentable {
    let directory: String
    let notebookID: String
    func makeNSView(context: Context) -> Bridge { let view = Bridge(); view.directory = directory; view.notebookID = notebookID; return view }
    func updateNSView(_ view: Bridge, context: Context) { view.directory = directory; view.notebookID = notebookID }
    final class Entry { weak var view: Bridge?; init(_ view: Bridge) { self.view = view } }
    @MainActor static var entries: [Entry] = []
    @MainActor static func target(at point: NSPoint, window: NSWindow) -> Bridge? {
        entries.removeAll { $0.view == nil }
        return entries.compactMap(\.view).filter { $0.window === window && !$0.isHidden && $0.visibleRect.contains($0.convert(point, from: nil)) }
            .max { $0.directory.components(separatedBy: "/").count < $1.directory.components(separatedBy: "/").count }
    }
    final class Bridge: NSView {
        var directory = "", notebookID = ""
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil, !LibraryNativeDropArea.entries.contains(where: { $0.view === self }) { LibraryNativeDropArea.entries.append(Entry(self)) }
        }
    }
}

struct LibraryDropTarget: ViewModifier {
    @ObservedObject var model: Workbench
    let directory: String
    let notebookID: String
    @State private var targeted = false
    func body(content: Content) -> some View {
        content
            .background(LibraryNativeDropArea(directory: directory, notebookID: notebookID))
            .background(targeted || model.libraryDropDestination == notebookID + ":" + directory ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .onDrop(of: [LibraryDragPayload.type, UTType.fileURL.identifier], isTargeted: $targeted) { providers in
                guard model.canManageFiles else { return false }
                if let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(LibraryDragPayload.type) }) {
                    provider.loadDataRepresentation(forTypeIdentifier: LibraryDragPayload.type) { data, _ in
                        guard let data, let payload = try? JSONDecoder().decode(LibraryDragPayload.self, from: data) else { return }
                        Task { @MainActor in
                            guard payload.workspace == model.workspace?.root.path else { return }
                            model.moveLibraryItems(payload.items, into: directory, notebookID: notebookID)
                        }
                    }
                    return true
                }
                for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                        guard let data, let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL else { return }
                        Task { @MainActor in model.importLibraryFiles([url], into: directory, notebookID: notebookID) }
                    }
                }
                return !providers.isEmpty
            }
    }
}
