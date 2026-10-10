import SwiftUI
import AppKit

/// Route library shortcuts only while the sidebar owns focus. Native text paste
/// and file dialogs keep their own responder chain.
struct NotebookLibraryClipboard: NSViewRepresentable {
    @ObservedObject var model: Workbench
    func makeNSView(context: Context) -> Bridge { let view = Bridge(); view.model = model; return view }
    func updateNSView(_ view: Bridge, context: Context) { view.model = model }
    static func dismantleNSView(_ view: Bridge, coordinator: ()) { view.stop() }
    final class Bridge: NSView {
        weak var model: Workbench?
        private var monitor: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
                return handled ? nil : event
            }
        }
        func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
        private func handle(_ event: NSEvent) -> Bool {
            guard let window, event.window === window, window.isKeyWindow, window.attachedSheet == nil, let model else { return false }
            // The sidebar list holds focus; row clicks never reach this monitor.
            guard let focused = window.firstResponder as? NSTableView, bounds.intersects(convert(focused.bounds, from: focused)), model.canManageFiles,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else { return false }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c": model.copyLibraryItem(model.librarySelection); return true
            case "v": model.pasteLibraryItems(into: model.libraryDestination, notebookID: model.currentNotebook.id); return true
            default: return false
            }
        }
    }
}
