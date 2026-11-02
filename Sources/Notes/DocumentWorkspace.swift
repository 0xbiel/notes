import Foundation

enum DocumentSplitAxis: String, Codable { case horizontal, vertical }

enum DocumentPaneEdge: String, CaseIterable {
    case left, right, top, bottom, center
    var axis: DocumentSplitAxis { self == .top || self == .bottom ? .vertical : .horizontal }
    var before: Bool { self == .left || self == .top }

    static func resolve(at point: CGPoint, size: CGSize) -> Self? {
        guard size.width > 0, size.height > 0, CGRect(origin: .zero, size: size).contains(point) else { return nil }
        let x = point.x / size.width, y = point.y / size.height
        let distances: [(Self, CGFloat)] = [(.left, x), (.right, 1 - x), (.top, y), (.bottom, 1 - y)]
        let closest = distances.min { $0.1 < $1.1 }!
        return closest.1 <= 0.25 ? closest.0 : .center
    }

    func frame(in size: CGSize) -> CGRect {
        var rect = CGRect(origin: .zero, size: size)
        switch self {
        case .left: rect.size.width /= 2
        case .right: rect.origin.x = size.width / 2; rect.size.width /= 2
        case .top: rect.size.height /= 2
        case .bottom: rect.origin.y = size.height / 2; rect.size.height /= 2
        case .center: break
        }
        return rect.insetBy(dx: 4, dy: 4)
    }
}

struct DocumentPaneDropTarget: Equatable {
    let paneID: String
    let edge: DocumentPaneEdge
}

struct WorkspaceDocument: Codable, Equatable, Identifiable {
    var id = UUID().uuidString
    var path: String
    var mode = "preview"
}

/// The layout contains only visible tabs. Other tabs stay open without occupying a pane.
indirect enum DocumentPaneLayout: Codable, Equatable {
    case pane(String)
    case split(id: String, axis: DocumentSplitAxis, fraction: Double, first: DocumentPaneLayout, second: DocumentPaneLayout)

    var tabs: [String] {
        switch self {
        case .pane(let id): [id]
        case .split(_, _, _, let first, let second): first.tabs + second.tabs
        }
    }

    func replacing(_ tab: String, with replacement: DocumentPaneLayout?) -> DocumentPaneLayout? {
        switch self {
        case .pane(let id): return id == tab ? replacement : self
        case .split(let id, let axis, let fraction, let first, let second):
            let a = first.replacing(tab, with: replacement), b = second.replacing(tab, with: replacement)
            guard let a else { return b }
            guard let b else { return a }
            return .split(id: id, axis: axis, fraction: fraction, first: a, second: b)
        }
    }

    func resizing(_ split: String, fraction: Double) -> DocumentPaneLayout {
        guard fraction.isFinite else { return self }
        switch self {
        case .pane: return self
        case .split(let id, let axis, let old, let first, let second):
            return .split(id: id, axis: axis, fraction: id == split ? min(0.85, max(0.15, fraction)) : old,
                          first: first.resizing(split, fraction: fraction), second: second.resizing(split, fraction: fraction))
        }
    }
}

struct DocumentWorkspace: Codable, Equatable {
    var documents: [WorkspaceDocument] = []
    var root: DocumentPaneLayout?
    var focusedID: String?
    var expandedID: String?
    var focused: WorkspaceDocument? { documents.first { $0.id == focusedID } }
    var visibleIDs: [String] { root?.tabs ?? [] }

    mutating func open(_ path: String) {
        // Keep a duplicate pane selected when opening the same document again.
        if focused?.path == path { return }
        if let existing = documents.first(where: { $0.path == path && visibleIDs.contains($0.id) }) ?? documents.first(where: { $0.path == path }) {
            select(existing.id); return
        }
        let document = WorkspaceDocument(path: path)
        documents.append(document)
        show(document.id)
    }

    mutating func select(_ id: String) {
        guard documents.contains(where: { $0.id == id }) else { return }
        show(id)
    }

    private mutating func show(_ id: String) {
        if !visibleIDs.contains(id) {
            if let focusedID, let root { self.root = root.replacing(focusedID, with: .pane(id)) }
            else { root = .pane(id) }
        }
        focusedID = id
        if expandedID != nil { expandedID = id }
    }

    @discardableResult mutating func split(path: String? = nil, axis: DocumentSplitAxis, before: Bool = false) -> String? {
        guard let focused, let root else { return nil }
        var document = WorkspaceDocument(path: path ?? focused.path)
        document.mode = focused.mode
        documents.append(document)
        let old = DocumentPaneLayout.pane(focused.id), new = DocumentPaneLayout.pane(document.id)
        self.root = root.replacing(focused.id, with: .split(id: UUID().uuidString, axis: axis, fraction: 0.5,
                                                           first: before ? new : old, second: before ? old : new))
        focusedID = document.id; expandedID = nil
        return document.id
    }

    mutating func close(_ id: String) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        documents.remove(at: index)
        root = root?.replacing(id, with: nil)
        if expandedID == id { expandedID = nil }
        if focusedID == id {
            focusedID = visibleIDs.first
            if focusedID == nil, !documents.isEmpty { show(documents[min(index, documents.count - 1)].id) }
        }
        if visibleIDs.count <= 1 { expandedID = nil }
    }

    mutating func toggleExpanded(_ id: String) {
        guard visibleIDs.contains(id), visibleIDs.count > 1 else { return }
        focusedID = id
        expandedID = expandedID == id ? nil : id
    }

    mutating func setMode(_ mode: String) {
        guard let index = documents.firstIndex(where: { $0.id == focusedID }) else { return }
        documents[index].mode = mode == "edit" ? "edit" : "preview"
    }

    mutating func swap(_ a: String, _ b: String) {
        guard a != b, visibleIDs.contains(a), visibleIDs.contains(b), let root else { return }
        let temporary = UUID().uuidString
        self.root = root.replacing(a, with: .pane(temporary))?.replacing(b, with: .pane(a))?.replacing(temporary, with: .pane(b))
    }

    @discardableResult mutating func insert(path: String, at target: DocumentPaneDropTarget) -> String? {
        guard let root, visibleIDs.contains(target.paneID) else { return nil }
        let document = WorkspaceDocument(path: path)
        documents.append(document)
        let replacement = placed(document.id, beside: target)
        self.root = root.replacing(target.paneID, with: replacement)
        focusedID = document.id; expandedID = nil
        return document.id
    }

    mutating func move(_ id: String, to target: DocumentPaneDropTarget) {
        guard id != target.paneID, visibleIDs.contains(id), visibleIDs.contains(target.paneID) else { return }
        if target.edge == .center { swap(id, target.paneID) }
        else {
            root = root?.replacing(id, with: nil)?.replacing(target.paneID, with: placed(id, beside: target))
        }
        focusedID = id; expandedID = nil
    }

    private func placed(_ id: String, beside target: DocumentPaneDropTarget) -> DocumentPaneLayout {
        if target.edge == .center { return .pane(id) }
        let old = DocumentPaneLayout.pane(target.paneID), new = DocumentPaneLayout.pane(id)
        return .split(id: UUID().uuidString, axis: target.edge.axis, fraction: 0.5,
                      first: target.edge.before ? new : old, second: target.edge.before ? old : new)
    }

    mutating func remapPaths(_ transform: (String) -> String) {
        for index in documents.indices { documents[index].path = transform(documents[index].path) }
    }

    mutating func retainPaths(_ allowed: Set<String>) {
        for document in documents where !allowed.contains(document.path) { close(document.id) }
    }

    /// Discard invalid/stale restoration data rather than rendering duplicate or missing leaves.
    var isValid: Bool {
        let ids = documents.map(\.id), visible = visibleIDs
        return Set(ids).count == ids.count && Set(visible).count == visible.count &&
            Set(visible).isSubset(of: Set(ids)) &&
            (documents.isEmpty ? root == nil && focusedID == nil : focusedID.map(visible.contains) == true) &&
            (expandedID == nil || visible.contains(expandedID!)) && validFractions(root)
    }

    private func validFractions(_ node: DocumentPaneLayout?) -> Bool {
        guard let node else { return true }
        switch node {
        case .pane: return true
        case .split(_, _, let fraction, let a, let b):
            return fraction.isFinite && (0.15...0.85).contains(fraction) && validFractions(a) && validFractions(b)
        }
    }
}
