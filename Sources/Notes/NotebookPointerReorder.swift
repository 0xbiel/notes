import AppKit

/// Pointer-only reordering. No pasteboard, native drag session, or outline delegate replacement.
struct NotebookPointerReorder {
    struct Header {
        let id: String
        let rect: NSRect
        var subtreeEnd: CGFloat? = nil
    }
    enum Result: Equatable {
        case click(String)
        case move(String, String, Bool)
    }
    private(set) var source: String?
    private var origin = NSPoint.zero
    private var dragging = false
    private var inside = true
    private var target: (String, Bool)?
    private(set) var insertionY: CGFloat?

    mutating func begin(id: String, at point: NSPoint) {
        cancel()
        source = id
        origin = point
        inside = true
    }
    mutating func move(to point: NSPoint, headers: [Header], inside: Bool) {
        guard source != nil else { return }
        self.inside = inside
        dragging = dragging || hypot(point.x - origin.x, point.y - origin.y) >= 5
        target = nil
        insertionY = nil
        guard dragging, inside, !headers.isEmpty else { return }
        // Descendants belong to their notebook; the next boundary is below its entire subtree.
        let index = headers.lastIndex(where: { point.y >= $0.rect.minY }) ?? 0
        let header = headers[index]
        let after = point.y >= header.rect.midY
        guard header.id != source else { return }
        target = (header.id, after)
        insertionY = after && index + 1 < headers.count ? headers[index + 1].rect.minY
            : (after ? (header.subtreeEnd ?? header.rect.maxY) : header.rect.minY)
    }
    mutating func finish() -> Result? {
        defer { cancel() }
        guard let source, inside else { return nil }
        if !dragging { return .click(source) }
        guard let target else { return nil }
        return .move(source, target.0, target.1)
    }
    mutating func cancel() {
        source = nil
        target = nil
        dragging = false
        insertionY = nil
    }
}
