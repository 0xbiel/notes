import SwiftUI
import LectureCore

struct MarkdownTableEditingSheet: View {
    @State var table: MarkdownTable
    var save: (MarkdownTable) -> Void
    var cancel: () -> Void
    @State var selectedRow = 0
    @State var selectedColumn = 0
    @AppStorage("notes.language") private var language = "es"
    private var index: Int? { table.cellIndex(row: selectedRow, column: selectedColumn) }
    private func text(_ en: String, _ es: String) -> String { language == "en" ? en : es }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(text("Table", "Tabla")).font(.title2.weight(.semibold)); Spacer()
                Text("\(table.rows) × \(table.columns)").foregroundStyle(.secondary).monospacedDigit()
            }
            HStack {
                Button(text("Add row", "Añadir fila")) { table.appendRow() }
                Button(text("Add column", "Añadir columna")) { table.appendColumn() }
                Spacer()
                Button(text("Delete row", "Eliminar fila")) { table.deleteRow(selectedRow); selectedRow = min(selectedRow, table.rows - 1) }.disabled(table.rows == 1)
                Button(text("Delete column", "Eliminar columna")) { table.deleteColumn(selectedColumn); selectedColumn = min(selectedColumn, table.columns - 1) }.disabled(table.columns == 1)
            }.buttonStyle(.borderless)
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    ForEach(Array(table.cells.enumerated()), id: \.offset) { i, cell in
                        Button { selectedRow = cell.row; selectedColumn = cell.column } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(table.cells[i].text.isEmpty ? " " : table.cells[i].text).lineLimit(3).frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                                if table.cells[i].rowSpan > 1 || table.cells[i].columnSpan > 1 { Text("\(table.cells[i].rowSpan) × \(table.cells[i].columnSpan)").font(.caption2).foregroundStyle(.secondary) }
                            }.padding(9).frame(width: CGFloat(cell.columnSpan) * 198 - 2, height: CGFloat(cell.rowSpan) * 72 - 2, alignment: .topLeading)
                                .background(i == index ? Color.primary.opacity(0.12) : Color.primary.opacity(cell.row == 0 ? 0.07 : 0.035), in: RoundedRectangle(cornerRadius: 5))
                                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator.opacity(0.5)))
                        }.buttonStyle(.plain).accessibilityLabel(text("Cell", "Celda") + " \(cell.row + 1), \(cell.column + 1)")
                            .offset(x: CGFloat(cell.column) * 198, y: CGFloat(cell.row) * 72)
                    }
                }.frame(width: CGFloat(table.columns) * 198, height: CGFloat(table.rows) * 72).padding(2)
            }.frame(minHeight: 150)
            if let index {
                Text(text("Cell \(selectedRow + 1), \(selectedColumn + 1)", "Celda \(selectedRow + 1), \(selectedColumn + 1)")).font(.caption).foregroundStyle(.secondary)
                TextField(text("Cell content", "Contenido de la celda"), text: Binding(get: { self.index.map { table.cells[$0].text } ?? "" }, set: { if let current = self.index { table.cells[current].text = $0 } }), axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(2...5).padding(10).modifier(NotebookInputSurface()).accessibilityIdentifier("table.cellText")
                HStack {
                    Button(text("Merge right", "Combinar a la derecha")) { _ = table.merge(at: index, horizontally: true) }.disabled(table.mergeNeighbor(at: index, horizontally: true) == nil)
                    Button(text("Merge down", "Combinar hacia abajo")) { _ = table.merge(at: index, horizontally: false) }.disabled(table.mergeNeighbor(at: index, horizontally: false) == nil)
                    Button(text("Split cell", "Dividir celda")) { table.split(at: index) }.disabled(table.cells[index].rowSpan == 1 && table.cells[index].columnSpan == 1)
                    Spacer()
                    Picker(text("Alignment", "Alineación"), selection: $table.alignments[selectedColumn]) {
                        Text(text("Left", "Izquierda")).tag(MarkdownTable.Alignment.left)
                        Text(text("Center", "Centro")).tag(MarkdownTable.Alignment.center)
                        Text(text("Right", "Derecha")).tag(MarkdownTable.Alignment.right)
                    }.frame(width: 150)
                }.buttonStyle(.borderless)
            }
            HStack {
                if table.cells.contains(where: { $0.rowSpan > 1 || $0.columnSpan > 1 }) { Text(text("Merged cells are saved as an HTML table.", "Las celdas combinadas se guardan como tabla HTML.")).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button(text("Cancel", "Cancelar"), action: cancel).keyboardShortcut(.cancelAction)
                Button(text("Apply", "Aplicar")) { save(table) }.keyboardShortcut(.defaultAction)
            }
        }.padding(22).frame(minWidth: 660, idealWidth: 760, minHeight: 540)
    }
}
