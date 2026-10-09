import XCTest
import AppKit
import SwiftUI
import LectureCore
@testable import Notes

final class MarkdownTableTests: XCTestCase {
    private let salaryTable = """
    | Percepciones salariales | Percepciones extrasalariales |
    | --- | --- |
    | Salario base: 60 €/día en octubre (31 días) — 1.860 € | Dietas — 120 € |
    | Antigüedad — 100 € | Ropa de trabajo — 20 € |
    | Plus de productividad — 120 € | Indemnización por traslado — 5.000 € |
    | Parte proporcional de la paga de verano — 110 € | |
    | Parte proporcional de la paga de Navidad — 110 € | |
    """
    func testPipeTablesEmptyCellsAlignmentEscapesCodeAndUTF16Ranges() throws {
        let source = "👩🏽‍💻 Before\n\n" + salaryTable + "\n\nAfter\n\n```md\n" + salaryTable + "\n```\n"
        let blocks = MarkdownTables.blocks(in: source)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual((source as NSString).substring(with: blocks[0].range), salaryTable)
        XCTAssertEqual(blocks[0].table.rows, 6); XCTAssertEqual(blocks[0].table.columns, 2)
        XCTAssertEqual(blocks[0].table.cells.last?.text, "")
        let special = try XCTUnwrap(MarkdownTables.blocks(in: "A | B | C\n:--- | :---: | ---:\nx\\|y | `a|b` | [[Note|Label]]").first?.table)
        XCTAssertEqual(special.alignments, [.left, .center, .right])
        XCTAssertEqual(special.cells[3].text, "x|y"); XCTAssertEqual(special.cells[4].text, "`a|b`")
        XCTAssertEqual(special.cells[5].text, "[[Note|Label]]")
        XCTAssertEqual(MarkdownTables.blocks(in: special.source).first?.table, special)
        XCTAssertTrue(MarkdownTables.blocks(in: "ordinary | text\nno | delimiter").isEmpty)
    }
    func testMergeSplitDeleteAndHTMLRoundTripPreserveContent() throws {
        var table = try XCTUnwrap(MarkdownTables.blocks(in: salaryTable).first?.table)
        table.alignments[0] = .center
        let index = try XCTUnwrap(table.cellIndex(row: 4, column: 0))
        XCTAssertTrue(table.merge(at: index, horizontally: true))
        let vertical = try XCTUnwrap(table.cellIndex(row: 4, column: 0))
        XCTAssertTrue(table.merge(at: try XCTUnwrap(table.cellIndex(row: 5, column: 0)), horizontally: true))
        XCTAssertTrue(table.merge(at: vertical, horizontally: false))
        XCTAssertTrue(table.source.contains("colspan=\"2\"")); XCTAssertTrue(table.source.contains("rowspan=\"2\""))
        let decoded = try XCTUnwrap(MarkdownTables.html(table.source))
        XCTAssertEqual(decoded.cells.sorted { ($0.row, $0.column) < ($1.row, $1.column) }, table.cells.sorted { ($0.row, $0.column) < ($1.row, $1.column) })
        XCTAssertEqual(decoded.alignments, table.alignments)
        XCTAssertTrue(decoded.cells[vertical].text.contains("verano")); XCTAssertTrue(decoded.cells[vertical].text.contains("Navidad"))
        table.split(at: vertical); XCTAssertFalse(table.source.contains("<table>"))
        table.deleteRow(4); table.deleteColumn(1); table.appendRow(); table.appendColumn()
        for row in 0..<table.rows { for col in 0..<table.columns { XCTAssertNotNil(table.cellIndex(row: row, column: col)) } }
        XCTAssertEqual(MarkdownTables.blocks(in: table.source).first?.table, table)
        XCTAssertNil(MarkdownTables.html("<!DOCTYPE table [<!ENTITY a SYSTEM 'file:///tmp/private'>]><table><tr><td>&a;</td></tr></table>"))
        XCTAssertNil(MarkdownTables.html("<table><tr><td rowspan=\"9\">Bad</td></tr></table>"))
    }
    @MainActor func testNativeTableReservesHeightRevealsSourceAndKeepsUndo() throws {
        _ = NSApplication.shared
        let view = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 780, height: 700))
        let source = "Before\n\n" + salaryTable + "\n\nAfter\n"
        view.string = source; view.isEditable = true; view.liveEditing = false; view.renderMarkdown()
        XCTAssertEqual(view.string, source); XCTAssertEqual(view.renderedTables.count, 1)
        let presentation = try XCTUnwrap(view.renderedTables.first), rect = try XCTUnwrap(view.tableRect(presentation))
        XCTAssertGreaterThan(rect.height, 200)
        let after = (source as NSString).range(of: "After")
        view.layoutManager!.ensureLayout(for: view.textContainer!)
        let glyph = view.layoutManager!.glyphIndexForCharacter(at: after.location)
        let afterLine = view.layoutManager!.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        XCTAssertGreaterThanOrEqual(afterLine.minY + view.textContainerOrigin.y, rect.maxY - 2)
        view.liveEditing = true; view.setSelectedRange(NSRange(location: presentation.block.range.location + 4, length: 0)); view.renderMarkdown()
        XCTAssertEqual(view.renderedTables.count, 1)
        XCTAssertLessThan((view.textStorage!.attribute(.font, at: presentation.block.range.location, effectiveRange: nil) as! NSFont).pointSize, 1)
        var changed = presentation.block.table; changed.cells[2].text = "Edited amount"; _ = changed.merge(at: 2, horizontally: true)
        XCTAssertTrue(view.applyMarkdownTable(changed, replacing: presentation.block.range, expectedSource: source, inserting: false))
        XCTAssertTrue(view.string.contains("<table>")); XCTAssertTrue(view.string.contains("Edited amount"))
        view.undo(nil); XCTAssertEqual(view.string, source)
        view.redo(nil); XCTAssertTrue(view.string.contains("Edited amount"))
        XCTAssertFalse(view.applyMarkdownTable(changed, replacing: presentation.block.range, expectedSource: source, inserting: false))
    }
    @MainActor func testVisualCellEditingRowColumnActionsAndUndoPreserveSurroundingText() throws {
        _ = NSApplication.shared
        let view = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 780, height: 700))
        let source = "Before\n\n" + salaryTable + "\n\nAfter\n"
        view.string = source; view.isEditable = true; view.liveEditing = true; view.renderMarkdown()
        XCTAssertEqual(view.renderedTables.count, 1); XCTAssertEqual(view.tableControls.count, 2)
        let table = try XCTUnwrap(view.renderedTables.first)
        let rect = try XCTUnwrap(view.tableRect(table))
        XCTAssertTrue(view.tableControls.allSatisfy { $0.title == "+" })
        XCTAssertGreaterThan(view.tableControls[0].frame.minY, rect.maxY)
        XCTAssertGreaterThan(view.tableControls[1].frame.minX, rect.maxX)
        view.beginInlineTableCell(table, cellIndex: 2)
        let session = try XCTUnwrap(view.inlineTableCell)
        session.field.stringValue = "Edited salary"
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: session.field))
        XCTAssertTrue(view.string.contains("Edited salary")); XCTAssertTrue(view.string.hasPrefix("Before\n\n")); XCTAssertTrue(view.string.hasSuffix("\n\nAfter\n"))
        XCTAssertEqual(view.renderedTables.count, 1)
        view.finishInlineTableCell()
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        let edited = view.string
        XCTAssertTrue(view.changeVisualTable(try XCTUnwrap(view.tableBlocks.first), command: "row", row: 0, column: 0, expectedSource: edited))
        XCTAssertEqual(view.tableBlocks.first?.table.rows, 7)
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        view.undo(nil); view.renderMarkdown(); XCTAssertEqual(view.string, edited)
        XCTAssertTrue(view.changeVisualTable(try XCTUnwrap(view.tableBlocks.first), command: "deleteColumn", row: 0, column: 1, expectedSource: edited))
        XCTAssertEqual(view.tableBlocks.first?.table.columns, 1)
        XCTAssertFalse(view.changeVisualTable(table.block, command: "deleteTable", row: 0, column: 0, expectedSource: source))
    }
    @MainActor func testSpreadsheetSelectionClipboardAndSelectedDeletion() throws {
        let view = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 780, height: 700))
        view.string = "Before\n\n| A | B | C |\n| --- | --- | --- |\n| one | two | three |\n| four | five | six |\n\nAfter\n"
        view.isEditable = true; view.liveEditing = true; view.renderMarkdown()
        let rendered = try XCTUnwrap(view.renderedTables.first)
        view.selectTableCell(rendered, cellIndex: 3, extending: false)
        view.selectTableCell(rendered, cellIndex: 7, extending: true)
        XCTAssertEqual(view.selectedTableText(), "one\ttwo\nfour\tfive")
        XCTAssertTrue(view.pasteTableCells("\"x\ny\"\tsecond\r\nthird\tfourth\r\n"))
        XCTAssertEqual(view.tableBlocks.first?.table.cells[3].text, "x\ny")
        XCTAssertEqual(view.selectedTableText(), "\"x\ny\"\tsecond\nthird\tfourth")
        let block = try XCTUnwrap(view.selectedTableBlock)
        XCTAssertTrue(view.changeVisualTable(block, command: "deleteRow", row: 1, column: 0, expectedSource: view.string))
        XCTAssertEqual(view.tableBlocks.first?.table.rows, 2)
        XCTAssertEqual(view.tableBlocks.first?.table.cells[3].text, "third")
        XCTAssertTrue(view.changeVisualTable(try XCTUnwrap(view.selectedTableBlock), command: "deleteColumn", row: 1, column: 1, expectedSource: view.string))
        XCTAssertEqual(view.tableBlocks.first?.table.columns, 2)
        XCTAssertEqual(view.tableBlocks.first?.table.cells.map(\.text), ["A", "C", "third", "six"])
        XCTAssertTrue(view.string.hasPrefix("Before\n\n")); XCTAssertTrue(view.string.hasSuffix("\n\nAfter\n"))
        XCTAssertEqual(TableClipboard.decode(TableClipboard.encode([["a\tb", "c\"d"], ["", "e\nf"]])), [["a\tb", "c\"d"], ["", "e\nf"]])
        view.tableSelection?.source = "stale"
        XCTAssertFalse(view.pasteTableCells("bad"))
    }
    @MainActor func testChatTablesAndAccentLinkColorIncludingAppearanceRefresh() throws {
        _ = NSApplication.shared
        let blocks = NotebookChatMarkdown.blocks("Before\n\n" + salaryTable + "\n\nAfter")
        XCTAssertEqual(blocks.map(\.kind), ["paragraph", "table", "paragraph"])
        let view = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 400))
        view.string = "[Article](https://example.com) and [[Note|Notebook]]"; view.liveEditing = false
        view.taskAccent = .systemPurple; view.renderMarkdown()
        XCTAssertEqual(view.linkTextAttributes?[.foregroundColor] as? NSColor, .systemPurple)
        XCTAssertEqual(view.insertionPointColor, .systemPurple)
        for label in ["Article", "Notebook"] {
            let range = (view.string as NSString).range(of: label)
            XCTAssertEqual(view.textStorage!.attribute(.foregroundColor, at: range.location, effectiveRange: nil) as? NSColor, .systemPurple)
        }
        view.taskAccent = .systemOrange
        XCTAssertEqual(view.linkTextAttributes?[.foregroundColor] as? NSColor, .systemOrange)
        XCTAssertEqual(view.insertionPointColor, .systemOrange)
        XCTAssertEqual(view.textStorage!.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? NSColor, .systemOrange)
        let chatLink = NotebookChatMarkdown.inlineAttributed("[Article](https://example.com)", accent: .purple)
        XCTAssertEqual(chatLink.runs.first?.foregroundColor, Color.purple)
        var table = MarkdownTable(rows: 2, columns: 1); table.cells[1].text = "[Article](https://example.com)"
        let layout = MarkdownTableLayout(table: table, width: 500, accent: .systemPurple)
        XCTAssertEqual(layout.texts[1].attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor, .systemPurple)
    }
}
