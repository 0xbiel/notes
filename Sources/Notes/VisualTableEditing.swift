import AppKit
import LectureCore

@MainActor final class InlineTableCellEdit {
    var block: MarkdownTableBlock
    var expectedSource: String
    let row: Int
    let column: Int
    let field: NSTextField
    init(block: MarkdownTableBlock, source: String, cell: MarkdownTableCell, field: NSTextField) {
        self.block = block; expectedSource = source; row = cell.row; column = cell.column; self.field = field
    }
}

extension MarkdownTextView: NSTextFieldDelegate {
    func tableCell(at point: NSPoint) -> (table: RenderedMarkdownTable, index: Int)? {
        for table in renderedTables {
            guard let rect = tableRect(table), rect.contains(point) else { continue }
            let local = NSPoint(x: point.x - rect.minX, y: point.y - rect.minY)
            if let index = table.block.table.cells.indices.first(where: { table.layout.rect(table.block.table.cells[$0]).contains(local) }) { return (table, index) }
        }
        return nil
    }
    func beginInlineTableCell(_ table: RenderedMarkdownTable, cellIndex: Int) {
        guard isEditable, let rect = tableRect(table), table.block.table.cells.indices.contains(cellIndex) else { return }
        let cell = table.block.table.cells[cellIndex]
        selectTableCell(table, cellIndex: cellIndex, extending: false)
        let field = NSTextField(frame: table.layout.rect(cell).offsetBy(dx: rect.minX, dy: rect.minY).insetBy(dx: 4, dy: 4))
        field.stringValue = cell.text; field.font = .systemFont(ofSize: 14)
        field.isEditable = true; field.isSelectable = true; field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor; field.textColor = .labelColor
        field.bezelStyle = .roundedBezel; field.focusRingType = .none
        field.delegate = self; field.target = self; field.action = #selector(endInlineTableCell(_:))
        field.cell?.sendsActionOnEndEditing = true
        field.setAccessibilityLabel("Table cell \(cell.row + 1), \(cell.column + 1)")
        inlineTableCell = .init(block: table.block, source: string, cell: cell, field: field)
        addSubview(field); window?.makeFirstResponder(field)
    }
    func controlTextDidChange(_ notification: Notification) {
        guard let session = inlineTableCell, notification.object as? NSTextField === session.field else { return }
        var table = session.block.table
        guard let index = table.cellIndex(row: session.row, column: session.column), string == session.expectedSource else { return }
        table.cells[index].text = session.field.stringValue
        if applyMarkdownTable(table, replacing: session.block.range, expectedSource: session.expectedSource, inserting: false) {
            session.expectedSource = string
            tableSelection?.source = string
            if let updated = tableBlocks.first(where: { $0.range.location == session.block.range.location }) { session.block = updated }
            if let rendered = renderedTables.first(where: { $0.block.range.location == session.block.range.location }), let rect = tableRect(rendered), let cell = rendered.block.table.cells.first(where: { $0.row == session.row && $0.column == session.column }) {
                session.field.frame = rendered.layout.rect(cell).offsetBy(dx: rect.minX, dy: rect.minY).insetBy(dx: 4, dy: 4)
            }
        }
    }
    @objc func endInlineTableCell(_ sender: Any?) { finishInlineTableCell(); window?.makeFirstResponder(self) }
    func finishInlineTableCell() {
        guard let session = inlineTableCell else { return }
        inlineTableCell = nil; session.field.delegate = nil; session.field.target = nil; session.field.removeFromSuperview()
    }
    func syncVisualTableControls() {
        tableControls.forEach { $0.removeFromSuperview() }; tableControls = []
        guard liveEditing, isEditable else { finishInlineTableCell(); return }
        let english = UserDefaults.standard.string(forKey: "notes.language") == "en"
        for (index, table) in renderedTables.enumerated() {
            guard let rect = tableRect(table) else { continue }
            for command in ["row", "column"] {
                let label = command == "row" ? (english ? "Add row" : "Añadir fila") : (english ? "Add column" : "Añadir columna")
                let button = NSButton(title: "+", target: self, action: #selector(addVisualTablePart(_:)))
                button.bezelStyle = .roundRect; button.controlSize = .small
                button.font = .systemFont(ofSize: 11); button.tag = index; button.identifier = .init(command)
                button.frame = command == "row"
                    ? NSRect(x: rect.midX - 12, y: rect.maxY + 6, width: 24, height: 24)
                    : NSRect(x: rect.maxX + 6, y: rect.midY - 12, width: 24, height: 24)
                button.toolTip = label; button.setAccessibilityLabel(label)
                button.setAccessibilityIdentifier("table.add." + command)
                addSubview(button); tableControls.append(button)
            }
        }
    }
    @objc func addVisualTablePart(_ sender: NSButton) {
        finishInlineTableCell()
        guard renderedTables.indices.contains(sender.tag) else { return }
        let block = renderedTables[sender.tag].block
        _ = changeVisualTable(block, command: sender.identifier?.rawValue ?? "row", row: 0, column: 0, expectedSource: string)
    }
    func addVisualTableMenuItems(to menu: NSMenu) {
        let english = UserDefaults.standard.string(forKey: "notes.language") == "en"
        let commands: [(String, String, String)] = [
            ("row", "Add row", "Añadir fila"), ("column", "Add column", "Añadir columna"),
            ("deleteRow", "Delete row", "Eliminar fila"), ("deleteColumn", "Delete column", "Eliminar columna"),
            ("mergeRight", "Merge right", "Combinar a la derecha"), ("mergeDown", "Merge down", "Combinar hacia abajo"),
            ("split", "Split cell", "Dividir celda"), ("deleteTable", "Delete table", "Eliminar tabla")
        ]
        for (command, en, es) in commands {
            let item = NSMenuItem(title: english ? en : es, action: #selector(visualTableMenuAction(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = command; menu.addItem(item)
        }
    }
    @objc func visualTableMenuAction(_ sender: NSMenuItem) {
        guard let block = contextTable, let command = sender.representedObject as? String else { return }
        _ = changeVisualTable(block, command: command, row: contextTableCell?.row ?? tableSelection?.row ?? 0, column: contextTableCell?.column ?? tableSelection?.column ?? 0, expectedSource: contextTableSource)
    }
    @discardableResult func changeVisualTable(_ block: MarkdownTableBlock, command: String, row: Int, column: Int, expectedSource: String) -> Bool {
        guard isEditable, string == expectedSource else { return false }
        if command == "deleteTable" {
            breakUndoCoalescing(); insertText("", replacementRange: block.range); breakUndoCoalescing(); renderMarkdown(); return true
        }
        var table = block.table
        switch command {
        case "row": table.appendRow()
        case "column": table.appendColumn()
        case "deleteRow": table.deleteRow(row)
        case "deleteColumn": table.deleteColumn(column)
        case "mergeRight", "mergeDown":
            guard let index = table.cellIndex(row: row, column: column), table.merge(at: index, horizontally: command == "mergeRight") else { return false }
        case "split": if let index = table.cellIndex(row: row, column: column) { table.split(at: index) }
        default: return false
        }
        let applied = applyMarkdownTable(table, replacing: block.range, expectedSource: expectedSource, inserting: false)
        if applied {
            tableSelection = .init(location: block.range.location, source: string, anchorRow: min(row, table.rows - 1), anchorColumn: min(column, table.columns - 1), row: min(row, table.rows - 1), column: min(column, table.columns - 1)); needsDisplay = true
        }
        return applied
    }
}
