import AppKit
import SwiftUI
import LectureCore

struct RenderedMarkdownTable {
    let block: MarkdownTableBlock
    let firstLine: NSRange
    let foldedRange: NSRange?
    let layout: MarkdownTableLayout
}

struct MarkdownTableLayout {
    let table: MarkdownTable
    let width: CGFloat
    let rowHeights: [CGFloat]
    let texts: [NSAttributedString]
    var height: CGFloat { rowHeights.reduce(0, +) }
    @MainActor init(table: MarkdownTable, width: CGFloat, accent: NSColor = .controlAccentColor) {
        self.table = table; self.width = max(80, width)
        let columnWidth = max(80, width) / CGFloat(table.columns)
        texts = table.cells.map { cell in
            let result = NSMutableAttributedString(attributedString: MarkdownMathText.attributed(
                cell.text, fontSize: 14, weight: cell.row == 0 ? .semibold : .regular, accent: accent))
            let all = NSRange(location: 0, length: result.length)
            let style = NSMutableParagraphStyle(); style.lineSpacing = 2
            style.alignment = table.alignments[cell.column] == .center ? .center : table.alignments[cell.column] == .right ? .right : .left
            result.addAttribute(.paragraphStyle, value: style, range: all)
            // Text drawn outside a text view paints .link in the system colour, so the target moves to
            // a private attribute and the link takes the notebook accent like those in the note body.
            result.enumerateAttribute(.link, in: all) { link, range, _ in
                guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) else { return }
                result.removeAttribute(.link, range: range)
                result.addAttributes([Self.linkKey: url, .foregroundColor: accent, .underlineStyle: NSUnderlineStyle.single.rawValue], range: range)
            }
            return result
        }
        var heights = Array(repeating: CGFloat(36), count: table.rows)
        for (index, cell) in table.cells.enumerated() where cell.rowSpan == 1 {
            let textHeight = texts[index].boundingRect(with: NSSize(width: max(10, columnWidth * CGFloat(cell.columnSpan) - 20), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading]).height
            heights[cell.row] = max(heights[cell.row], ceil(textHeight) + 18)
        }
        for (index, cell) in table.cells.enumerated() where cell.rowSpan > 1 {
            let textHeight = texts[index].boundingRect(with: NSSize(width: max(10, columnWidth * CGFloat(cell.columnSpan) - 20), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading]).height + 18
            let current = heights[cell.row..<(cell.row + cell.rowSpan)].reduce(0, +)
            if textHeight > current { for row in cell.row..<(cell.row + cell.rowSpan) { heights[row] += ceil((textHeight - current) / CGFloat(cell.rowSpan)) } }
        }
        rowHeights = heights
    }
    func rect(_ cell: MarkdownTableCell) -> NSRect {
        NSRect(x: CGFloat(cell.column) * width / CGFloat(table.columns), y: rowHeights.prefix(cell.row).reduce(0, +),
               width: CGFloat(cell.columnSpan) * width / CGFloat(table.columns), height: rowHeights[cell.row..<(cell.row + cell.rowSpan)].reduce(0, +))
    }
    static let linkKey = NSAttributedString.Key("palladium.tableLink")
    /// The link under a point given in the table's own coordinates.
    @MainActor func link(at point: NSPoint) -> URL? {
        guard let index = table.cells.indices.first(where: { rect(table.cells[$0]).contains(point) }), texts[index].length > 0 else { return nil }
        let box = rect(table.cells[index]).insetBy(dx: 10, dy: 8)
        let storage = NSTextStorage(attributedString: texts[index]), manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: box.width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0; manager.addTextContainer(container); storage.addLayoutManager(manager)
        let local = NSPoint(x: point.x - box.minX, y: point.y - box.minY), glyph = manager.glyphIndex(for: local, in: container)
        guard manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(local) else { return nil }
        return storage.attribute(Self.linkKey, at: manager.characterIndexForGlyph(at: glyph), effectiveRange: nil) as? URL
    }
    func draw(at origin: NSPoint) {
        let bounds = NSRect(origin: origin, size: NSSize(width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        let outer = NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7); outer.addClip()
        let border = NSColor.separatorColor.withAlphaComponent(0.55)
        for (index, cell) in table.cells.enumerated() {
            let box = rect(cell).offsetBy(dx: origin.x, dy: origin.y)
            let fill = NSColor.textBackgroundColor.blended(withFraction: cell.row == 0 ? 0.085 : (cell.row % 2 == 0 ? 0.025 : 0.012), of: .labelColor) ?? .controlBackgroundColor
            fill.setFill(); NSBezierPath(rect: box).fill()
            border.setStroke(); let grid = NSBezierPath(rect: box); grid.lineWidth = 0.6; grid.stroke()
            texts[index].draw(with: box.insetBy(dx: 10, dy: 8), options: [.usesLineFragmentOrigin, .usesFontLeading])
        }
        NSGraphicsContext.restoreGraphicsState()
        border.setStroke(); outer.lineWidth = 0.8; outer.stroke()
    }
}

struct MarkdownTablePreview: NSViewRepresentable {
    let table: MarkdownTable
    @AppStorage("notes.accent") private var accent = ""
    func makeNSView(context: Context) -> TableCanvas { TableCanvas() }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TableCanvas, context: Context) -> CGSize? {
        let width = proposal.width ?? 680
        return CGSize(width: width, height: MarkdownTableLayout(table: table, width: width).height)
    }
    func updateNSView(_ view: TableCanvas, context: Context) { view.table = table; view.accent = NSColor(NotebookAccent.color(accent)); view.invalidateIntrinsicContentSize(); view.needsDisplay = true }
    final class TableCanvas: NSView {
        var table = MarkdownTable()
        var accent = NSColor.controlAccentColor
        override var isFlipped: Bool { true }
        override var intrinsicContentSize: NSSize { .init(width: NSView.noIntrinsicMetric, height: MarkdownTableLayout(table: table, width: max(80, bounds.width)).height) }
        override func setFrameSize(_ newSize: NSSize) { let previous = bounds.width; super.setFrameSize(newSize); if previous != newSize.width { invalidateIntrinsicContentSize() }; needsDisplay = true }
        override func draw(_ dirtyRect: NSRect) { MarkdownTableLayout(table: table, width: bounds.width, accent: accent).draw(at: .zero) }
        override func accessibilityLabel() -> String? { table.cells.sorted { ($0.row, $0.column) < ($1.row, $1.column) }.map(\.text).joined(separator: ", ") }
        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .table }
        override func menu(for event: NSEvent) -> NSMenu? {
            let menu = NSMenu()
            let item = NSMenuItem(title: UserDefaults.standard.string(forKey: "notes.language") == "en" ? "Copy table" : "Copiar tabla", action: #selector(copyTable(_:)), keyEquivalent: "")
            item.target = self; menu.addItem(item); return menu
        }
        @objc private func copyTable(_ sender: Any?) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(table.source, forType: .string) }
    }
}
