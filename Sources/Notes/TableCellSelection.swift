import AppKit
import LectureCore

struct TableCellSelection {
    var location: Int
    var source: String
    var anchorRow: Int
    var anchorColumn: Int
    var row: Int
    var column: Int
    var rows: ClosedRange<Int> { min(anchorRow, row)...max(anchorRow, row) }
    var columns: ClosedRange<Int> { min(anchorColumn, column)...max(anchorColumn, column) }
}

enum TableClipboard {
    static func decode(_ text: String) -> [[String]]? {
        guard text.utf8.count <= 1_000_000 else { return nil }
        if text.isEmpty { return [[""]] }
        let chars = Array(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
        var rows: [[String]] = [], row: [String] = [], cell = "", quoted = false, index = 0
        while index < chars.count {
            let c = chars[index]
            if c == "\"" {
                if quoted, index + 1 < chars.count, chars[index + 1] == "\"" { cell.append(c); index += 1 }
                else if quoted || cell.isEmpty { quoted.toggle() } else { cell.append(c) }
            } else if !quoted && c == "\t" { row.append(cell); cell = "" }
            else if !quoted && c == "\n" { row.append(cell); rows.append(row); row = []; cell = "" }
            else { cell.append(c) }
            index += 1
        }
        guard !quoted else { return nil }
        if !row.isEmpty || !cell.isEmpty || chars.last != "\n" { row.append(cell); rows.append(row) }
        guard !rows.isEmpty, rows.count * (rows.map(\.count).max() ?? 0) <= 10_000 else { return nil }
        return rows
    }
    static func encode(_ rows: [[String]]) -> String {
        rows.map { $0.map { cell in
            cell.contains(where: { "\t\n\r\"".contains($0) }) ? "\"" + cell.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : cell
        }.joined(separator: "\t") }.joined(separator: "\n")
    }
}

extension MarkdownTextView {
    var selectedTableBlock: MarkdownTableBlock? {
        guard let selection = tableSelection, selection.source == string else { return nil }
        return tableBlocks.first { $0.range.location == selection.location }
    }
    func selectTableCell(_ rendered: RenderedMarkdownTable, cellIndex: Int, extending: Bool) {
        let cell = rendered.block.table.cells[cellIndex]
        if extending, var selection = tableSelection, selection.location == rendered.block.range.location, selection.source == string {
            selection.row = cell.row; selection.column = cell.column; tableSelection = selection
        } else { tableSelection = .init(location: rendered.block.range.location, source: string, anchorRow: cell.row, anchorColumn: cell.column, row: cell.row, column: cell.column) }
        needsDisplay = true
    }
    func drawTableSelection(_ rendered: RenderedMarkdownTable, at rect: NSRect) {
        guard liveEditing, let selection = tableSelection, selection.source == string, selection.location == rendered.block.range.location else { return }
        for cell in rendered.block.table.cells where selection.rows.contains(cell.row) && selection.columns.contains(cell.column) {
            let box = rendered.layout.rect(cell).offsetBy(dx: rect.minX, dy: rect.minY).insetBy(dx: 1, dy: 1)
            taskAccent.withAlphaComponent(0.13).setFill(); NSBezierPath(rect: box).fill()
            taskAccent.withAlphaComponent(0.8).setStroke(); let border = NSBezierPath(rect: box); border.lineWidth = 1.5; border.stroke()
        }
    }
    func selectedTableText() -> String? {
        guard let selection = tableSelection, let block = selectedTableBlock else { return nil }
        return TableClipboard.encode(selection.rows.map { row in selection.columns.map { column in
            guard let index = block.table.cellIndex(row: row, column: column) else { return "" }
            let cell = block.table.cells[index]
            return cell.row == row && cell.column == column ? cell.text : ""
        } })
    }
    @discardableResult func pasteTableCells(_ text: String) -> Bool {
        guard isEditable, let selection = tableSelection, let block = selectedTableBlock, let rows = TableClipboard.decode(text) else { return false }
        let startRow = selection.rows.lowerBound, startColumn = selection.columns.lowerBound
        let width = rows.map(\.count).max() ?? 1
        let rowCount = max(block.table.rows, startRow + rows.count), columnCount = max(block.table.columns, startColumn + width)
        guard rowCount * columnCount <= 10_000 else { return false }
        finishInlineTableCell()
        var table = block.table
        while table.rows < rowCount { table.appendRow() }; while table.columns < columnCount { table.appendColumn() }
        // Split intersecting merged cells before writing a rectangular spreadsheet range.
        for cell in table.cells where cell.row < startRow + rows.count && cell.row + cell.rowSpan > startRow && cell.column < startColumn + width && cell.column + cell.columnSpan > startColumn {
            if let index = table.cellIndex(row: cell.row, column: cell.column) { table.split(at: index) }
        }
        for (r, values) in rows.enumerated() { for c in 0..<width {
            if let index = table.cellIndex(row: startRow + r, column: startColumn + c) { table.cells[index].text = c < values.count ? values[c] : "" }
        } }
        guard applyMarkdownTable(table, replacing: block.range, expectedSource: selection.source, inserting: false) else { return false }
        tableSelection = .init(location: block.range.location, source: string, anchorRow: startRow, anchorColumn: startColumn, row: startRow + rows.count - 1, column: startColumn + width - 1)
        needsDisplay = true; return true
    }
    func handleTableKey(_ event: NSEvent) -> Bool {
        guard isEditable, var selection = tableSelection, let block = selectedTableBlock else { return false }
        if event.modifierFlags.contains(.command) { return false }
        let key = event.keyCode
        if [123, 124, 125, 126, 48].contains(key) {
            if key == 48 {
                let flat = selection.row * block.table.columns + selection.column + (event.modifierFlags.contains(.shift) ? -1 : 1)
                let clamped = max(0, min(block.table.rows * block.table.columns - 1, flat))
                selection.row = clamped / block.table.columns; selection.column = clamped % block.table.columns
            } else {
                selection.row = max(0, min(block.table.rows - 1, selection.row + (key == 125 ? 1 : key == 126 ? -1 : 0)))
                selection.column = max(0, min(block.table.columns - 1, selection.column + (key == 124 ? 1 : key == 123 ? -1 : 0)))
            }
            if !event.modifierFlags.contains(.shift) || key == 48 { selection.anchorRow = selection.row; selection.anchorColumn = selection.column }
            tableSelection = selection; needsDisplay = true; return true
        }
        if key == 51 || key == 117 {
            let blanks = selection.rows.map { _ in selection.columns.map { _ in "" } }
            return pasteTableCells(TableClipboard.encode(blanks))
        }
        if key == 53 { tableSelection = nil; needsDisplay = true; return true }
        if key == 36 || (event.characters?.unicodeScalars.contains(where: { !CharacterSet.controlCharacters.contains($0) }) == true) {
            guard let rendered = renderedTables.first(where: { $0.block.range.location == selection.location }), let index = block.table.cellIndex(row: selection.row, column: selection.column) else { return false }
            beginInlineTableCell(rendered, cellIndex: index)
            if key != 36, let editor = inlineTableCell?.field.currentEditor() { editor.insertText(event.characters ?? "") }
            return true
        }
        return false
    }
}
