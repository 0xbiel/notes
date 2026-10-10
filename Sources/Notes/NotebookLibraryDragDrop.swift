import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Names the library item a sidebar row shows. The pointer controller reads
/// these to resolve the row under the pointer; the marker takes no events.
struct LibraryRowMarker: NSViewRepresentable {
    let item: NotebookSidebarSelection
    func makeNSView(context: Context) -> Bridge { let view = Bridge(); view.item = item; return view }
    func updateNSView(_ view: Bridge, context: Context) { view.item = item }
    final class Entry { weak var view: Bridge?; init(_ view: Bridge) { self.view = view } }
    @MainActor static var entries: [Entry] = []
    @MainActor static func items(in table: NSTableView) -> [Int: NotebookSidebarSelection] {
        entries.removeAll { $0.view == nil }
        var items: [Int: NotebookSidebarSelection] = [:]
        for view in entries.compactMap(\.view) where view.window === table.window && !view.isHiddenOrHasHiddenAncestor {
            let row = table.row(for: view)
            if row >= 0 { items[row] = view.item }
        }
        return items
    }
    /// Where the row's icon and name end, in table coordinates.
    @MainActor static func labelEnd(row: Int, in table: NSTableView) -> CGFloat? {
        entries.compactMap(\.view).first { $0.window === table.window && table.row(for: $0) == row }.map { table.convert($0.bounds, from: $0).maxX }
    }
    final class Bridge: NSView {
        var item: NotebookSidebarSelection = .note("")
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil, !LibraryRowMarker.entries.contains(where: { $0.view === self }) { LibraryRowMarker.entries.append(Entry(self)) }
        }
    }
}

/// Where a drag would land: the folder or notebook owning the hovered row,
/// with the rows of that container for the highlight.
struct LibraryDropDestination: Equatable {
    var directory: String
    var notebookID: String
    var rows: ClosedRange<Int>
    @MainActor static func resolve(row: Int, in outline: NSOutlineView, model: Workbench) -> LibraryDropDestination? {
        guard row >= 0, let item = LibraryRowMarker.items(in: outline)[row] else { return nil }
        var first = row
        let directory: String, owner: String?
        switch item {
        case .notebook(let id):
            guard let notebook = model.activeNotebooks.first(where: { $0.id == id }) else { return nil }
            directory = notebook.rootPrefix; owner = id
        case .folder(let path): directory = path; owner = model.projects?.owner(of: path + "/placeholder")?.id
        case .note(let path):
            // A document row stands for the container that holds it.
            directory = path.components(separatedBy: "/").dropLast().joined(separator: "/"); owner = model.projects?.owner(of: path)?.id
            let level = outline.level(forRow: row)
            while first > 0, outline.level(forRow: first) >= level { first -= 1 }
        }
        guard let owner, model.activeNotebooks.contains(where: { $0.id == owner }) else { return nil }
        let level = outline.level(forRow: first)
        var last = first
        while last + 1 < outline.numberOfRows, outline.level(forRow: last + 1) > level { last += 1 }
        return .init(directory: directory, notebookID: owner, rows: first...last)
    }
}

struct LibraryPointerPress {
    /// Nil for a press on the empty area below the rows.
    let item: NotebookSidebarSelection?
    let row: Int
    let origin: NSPoint
    let wasSelected: Bool
    let modifiers: NSEvent.ModifierFlags
    /// Set once the pointer leaves the click threshold and the drag begins.
    var items: Set<NotebookSidebarSelection>?
    var destination: LibraryDropDestination?
    /// A press beside the name sweeps a selection over the rows instead of moving them.
    var sweeps = false
    var sweeping = false
    var base: Set<NotebookSidebarSelection> = []
    /// Rows the marquee has met; the list only keeps views for rows on screen.
    var seen: [Int: NotebookSidebarSelection] = [:]
    var hoverRow = -1
    var hoverStart = Date.distantFuture
}

/// The label that follows the pointer while documents or a notebook move.
struct LibraryDragChip: View {
    let symbol: String
    let title: String
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).foregroundStyle(.secondary)
            Text(title).font(.callout).lineLimit(1).truncationMode(.middle)
        }.padding(.horizontal, 10).frame(height: 30).frame(maxWidth: 230)
            .modifier(NotebookInputSurface(radius: 8, floating: true))
            .fixedSize().padding(LibraryDragChip.margin)
    }
    /// Room for the surface shadow inside the hosting view.
    static let margin: CGFloat = 16
    static func describe(_ items: Set<NotebookSidebarSelection>, model: Workbench) -> LibraryDragChip {
        func name(_ path: String) -> String { let name = URL(fileURLWithPath: path).lastPathComponent; return name.hasSuffix(".md") ? String(name.dropLast(3)) : name }
        if items.count > 1 {
            let english = UserDefaults.standard.string(forKey: "notes.language") == "en"
            return .init(symbol: "square.on.square", title: "\(items.count) " + (english ? "items" : "elementos"))
        }
        switch items.first {
        case .folder(let path): return .init(symbol: "folder", title: name(path))
        case .notebook(let id): return .init(symbol: "book.closed.fill", title: model.activeNotebooks.first { $0.id == id }?.name ?? "")
        case .note(let path): return .init(symbol: LibraryFileIcon.symbol(path), title: name(path))
        case nil: return .init(symbol: "doc", title: "")
        }
    }
}

/// One controller owns clicks and drags on sidebar rows. Taking the mouse-down
/// keeps the native table out of its own tracking loop, so a press can still
/// become a drag and a group survives a press on one of its rows.
extension NeutralSidebarSelection.SelectionBridge {
    private func headers(_ outline: NSOutlineView, _ model: Workbench) -> [NotebookPointerReorder.Header] {
        let roots = (0..<outline.numberOfRows).filter { outline.level(forRow: $0) == 0 }
        let ids = model.activeNotebooks.map(\.id)
        guard roots.count == ids.count, outline.numberOfRows > 0 else { return [] }
        let end = outline.rect(ofRow: outline.numberOfRows - 1).maxY
        return zip(ids, roots).map { .init(id: $0.0, rect: outline.rect(ofRow: $0.1), subtreeEnd: end) }
    }

    func cancelPointer() {
        pointer.cancel(); press = nil; lastDrag = nil
        dragTimer?.invalidate(); dragTimer = nil
        dragChip?.removeFromSuperview(); dragChip = nil
        selectionOverlay?.insertionY = nil; selectionOverlay?.pressedRow = nil; selectionOverlay?.dropRows = nil; selectionOverlay?.marquee = nil
        if model?.libraryExpandRequest != nil { model?.libraryExpandRequest = nil }
    }

    func handlePointer(_ event: NSEvent) -> NSEvent? {
        guard let outline = table as? NSOutlineView, let model, let window = outline.window else { return event }
        let active = press != nil || pointer.source != nil
        if event.type == .keyDown {
            guard active, event.keyCode == 53 else { return event }
            cancelPointer(); return nil
        }
        guard event.window === window else { return event }
        let point = outline.convert(event.locationInWindow, from: nil)
        switch event.type {
        case .leftMouseDown:
            cancelPointer()
            guard window.attachedSheet == nil, !event.modifierFlags.contains(.control), outline.visibleRect.contains(point),
                  let hit = (window.contentView?.superview ?? window.contentView)?.hitTest(event.locationInWindow), hit === outline || hit.isDescendant(of: outline) else { return event }
            let row = outline.row(at: point)
            let modifiers = event.modifierFlags.intersection([.command, .shift])
            guard row >= 0 else {
                window.makeFirstResponder(outline); sidebarFocused = true
                press = .init(item: nil, row: row, origin: point, wasSelected: false, modifiers: modifiers, sweeps: true, base: modifiers.isEmpty ? [] : model.librarySelections)
                refresh(); return nil
            }
            guard let item = LibraryRowMarker.items(in: outline)[row] else { return event }
            // The disclosure arrow stays native.
            let arrow = outline.frameOfOutlineCell(atRow: row)
            guard arrow.isEmpty || point.x < arrow.minX - 3 || point.x > arrow.maxX + 3 else { return event }
            window.makeFirstResponder(outline)
            sidebarFocused = true
            if case .notebook(let id) = item { pointer.begin(id: id, at: point); refresh(); return nil }
            let selected = outline.isRowSelected(row)
            press = .init(item: item, row: row, origin: point, wasSelected: selected, modifiers: modifiers)
            if let end = LibraryRowMarker.labelEnd(row: row, in: outline), point.x > end + 10 {
                press?.sweeps = true
                press?.base = modifiers.isEmpty ? [] : model.librarySelections
            }
            if modifiers.contains(.shift) {
                let documents = outline.selectedRowIndexes.filter { outline.level(forRow: $0) > 0 }
                let anchor = anchorRow.flatMap { documents.contains($0) ? $0 : nil } ?? documents.first ?? row
                let rows = (min(anchor, row)...max(anchor, row)).filter { outline.level(forRow: $0) > 0 }
                let known = LibraryRowMarker.items(in: outline), range = rows.compactMap { known[$0] }
                // The model selects directly; rows scrolled out of view have no item to read, so the list selects those.
                if range.count == rows.count { model.selectLibraryGroup(Set(range)) } else { outline.selectRowIndexes(IndexSet(rows), byExtendingSelection: false) }
                anchorRow = anchor
            } else {
                // Removing a row or reducing a group waits for mouse-up: the press may start a drag.
                if modifiers.contains(.command), !selected { model.toggleLibrarySelection(item) }
                anchorRow = row
            }
            selectionOverlay?.pressedRow = row
            refresh()
            return nil
        case .leftMouseDragged:
            guard active else { return event }
            lastDrag = event
            if pointer.source != nil {
                pointer.move(to: point, headers: headers(outline, model), inside: outline.visibleRect.contains(point))
                selectionOverlay?.insertionY = pointer.insertionY
                if pointer.dragging, let id = pointer.source { beginDrag([.notebook(id)], model: model, window: window) }
                moveChip(to: event.locationInWindow)
                return nil
            }
            guard var press else { return nil }
            if press.sweeps {
                guard press.sweeping || hypot(point.x - press.origin.x, point.y - press.origin.y) >= 4 else { return nil }
                if !press.sweeping { press.sweeping = true; self.press = press; startDragTimer() }
                updateSweep(at: event.locationInWindow)
                return nil
            }
            if press.items == nil, let item = press.item {
                guard model.canManageFiles, hypot(point.x - press.origin.x, point.y - press.origin.y) >= 4 else { return nil }
                let group = model.librarySelections.filter { if case .notebook = $0 { false } else { true } }
                press.items = group.contains(item) && (press.wasSelected || press.modifiers.contains(.command)) ? group : [item]
                self.press = press
                beginDrag(press.items!, model: model, window: window)
            }
            updateDrag(at: event.locationInWindow)
            return nil
        case .leftMouseUp:
            guard active else { return event }
            if pointer.source != nil {
                pointer.move(to: point, headers: headers(outline, model), inside: outline.visibleRect.contains(point))
                let result = pointer.finish()
                cancelPointer()
                switch result {
                case .click(let id): model.openNotebook(id)
                case .move(let id, let target, let after): model.reorderNotebook(id, relativeTo: target, after: after)
                case nil: break
                }
                return nil
            }
            guard let finished = press else { return nil }
            if finished.items != nil { updateDrag(at: event.locationInWindow) }
            let press = self.press ?? finished
            cancelPointer()
            if press.sweeping { refresh(); return nil }
            guard let item = press.item else { refresh(); return nil }
            if let items = press.items {
                if let destination = press.destination { model.moveLibraryItems(items, into: destination.directory, notebookID: destination.notebookID) }
            } else if press.modifiers.contains(.command) {
                if press.wasSelected { model.toggleLibrarySelection(item) }
            } else if !press.modifiers.contains(.shift), model.librarySelections != [item] || model.librarySelection != item {
                model.setLibrarySelections([item])
            }
            refresh()
            return nil
        default: return event
        }
    }

    private func beginDrag(_ items: Set<NotebookSidebarSelection>, model: Workbench, window: NSWindow) {
        guard dragChip == nil, let content = window.contentView else { return }
        let chip = NSHostingView(rootView: LibraryDragChip.describe(items, model: model))
        chip.frame.size = chip.fittingSize
        content.addSubview(chip, positioned: .above, relativeTo: nil)
        dragChip = chip
        startDragTimer()
    }

    /// Keeps scrolling and spring-loading alive while the pointer rests.
    private func startDragTimer() {
        guard dragTimer == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.dragTick() } }
        RunLoop.main.add(timer, forMode: .common)
        dragTimer = timer
    }

    private func moveChip(to location: NSPoint) {
        guard let chip = dragChip, let content = chip.superview else { return }
        let point = content.convert(location, from: nil), margin = LibraryDragChip.margin
        chip.frame.origin = NSPoint(x: point.x + 12 - margin, y: content.isFlipped ? point.y + 6 - margin : point.y - 6 + margin - chip.frame.height)
    }

    private func dragTick() {
        guard let outline = table as? NSOutlineView, let window = outline.window, let event = lastDrag else { return }
        outline.autoscroll(with: event)
        if press?.sweeping == true { updateSweep(at: window.mouseLocationOutsideOfEventStream); return }
        guard press?.items != nil else { return }
        updateDrag(at: window.mouseLocationOutsideOfEventStream)
        guard let press, press.hoverRow >= 0, Date().timeIntervalSince(press.hoverStart) >= 0.6,
              let item = LibraryRowMarker.items(in: outline)[press.hoverRow], let native = outline.item(atRow: press.hoverRow),
              outline.isExpandable(native), !outline.isItemExpanded(native), model?.libraryExpandRequest != item else { return }
        model?.libraryExpandRequest = item
    }

    /// Selects the document and folder rows the marquee crosses.
    private func updateSweep(at location: NSPoint) {
        guard let outline = table as? NSOutlineView, let press else { return }
        let point = outline.convert(location, from: nil)
        let marquee = NSRect(x: min(point.x, press.origin.x), y: min(point.y, press.origin.y), width: abs(point.x - press.origin.x), height: max(1, abs(point.y - press.origin.y)))
        selectionOverlay?.marquee = marquee
        selectionOverlay?.pressedRow = nil
        guard var press = self.press, let model else { return }
        press.seen.merge(LibraryRowMarker.items(in: outline)) { _, new in new }
        self.press = press
        let crossed = outline.rows(in: NSRect(x: 0, y: marquee.minY, width: outline.bounds.width, height: marquee.height))
        let items = (crossed.location..<(crossed.location + crossed.length)).compactMap { press.seen[$0] }
        model.selectLibraryGroup(press.base.union(items).filter { if case .notebook = $0 { false } else { true } })
        if press.row >= 0 { anchorRow = press.row }
    }

    private func updateDrag(at location: NSPoint) {
        guard let outline = table as? NSOutlineView, let model, var press, let items = press.items else { return }
        let point = outline.convert(location, from: nil)
        let row = outline.visibleRect.contains(point) ? outline.row(at: point) : -1
        var destination = LibraryDropDestination.resolve(row: row, in: outline, model: model)
        if let found = destination, !model.libraryMoveIsUseful(items, into: found.directory) { destination = nil }
        if row != press.hoverRow { press.hoverRow = row; press.hoverStart = Date() }
        press.destination = destination
        self.press = press
        selectionOverlay?.dropRows = destination?.rows
        // Rows shift when a folder springs open.
        selectionOverlay?.pressedRow = press.item.flatMap { item in LibraryRowMarker.items(in: outline).first { $0.value == item }?.key }
        moveChip(to: location)
    }
}

/// Files dragged in from Finder import into the folder or notebook they land on.
struct LibraryDropTarget: ViewModifier {
    @ObservedObject var model: Workbench
    let directory: String
    let notebookID: String
    @State private var targeted = false
    @AppStorage("notes.accent") private var accent = ""
    func body(content: Content) -> some View {
        content
            .background(targeted ? NotebookAccent.color(accent).opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $targeted) { providers in
                guard model.canManageFiles else { return false }
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
