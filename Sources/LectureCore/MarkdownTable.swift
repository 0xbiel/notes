import Foundation

public struct MarkdownTableCell: Equatable, Sendable {
    public var row: Int
    public var column: Int
    public var rowSpan = 1
    public var columnSpan = 1
    public var text: String
    public init(row: Int, column: Int, text: String, rowSpan: Int = 1, columnSpan: Int = 1) {
        self.row = row; self.column = column; self.text = text; self.rowSpan = rowSpan; self.columnSpan = columnSpan
    }
}
public struct MarkdownTable: Equatable, Sendable {
    public enum Alignment: String, Sendable { case left, center, right }
    public var rows: Int
    public var columns: Int
    public var cells: [MarkdownTableCell]
    public var alignments: [Alignment]
    public init(rows: Int = 3, columns: Int = 2) {
        self.rows = max(1, rows); self.columns = max(1, columns)
        cells = (0..<max(1, rows)).flatMap { row in (0..<max(1, columns)).map { MarkdownTableCell(row: row, column: $0, text: row == 0 ? "Column \($0 + 1)" : "") } }
        alignments = Array(repeating: .left, count: max(1, columns))
    }
    public func cellIndex(row: Int, column: Int) -> Int? {
        cells.firstIndex { row >= $0.row && row < $0.row + $0.rowSpan && column >= $0.column && column < $0.column + $0.columnSpan }
    }
    public mutating func appendRow() {
        cells += (0..<columns).map { .init(row: rows, column: $0, text: "") }; rows += 1
    }
    public mutating func appendColumn() {
        cells += (0..<rows).map { .init(row: $0, column: columns, text: "") }; columns += 1; alignments.append(.left)
        cells.sort { ($0.row, $0.column) < ($1.row, $1.column) }
    }
    public mutating func deleteRow(_ row: Int) {
        guard rows > 1, (0..<rows).contains(row) else { return }
        cells = cells.compactMap { original in
            var cell = original
            if cell.row == row && cell.rowSpan == 1 { return nil }
            if cell.row <= row && cell.row + cell.rowSpan > row { cell.rowSpan -= 1 }
            else if cell.row > row { cell.row -= 1 }
            return cell
        }; rows -= 1
    }
    public mutating func deleteColumn(_ column: Int) {
        guard columns > 1, (0..<columns).contains(column) else { return }
        cells = cells.compactMap { original in
            var cell = original
            if cell.column == column && cell.columnSpan == 1 { return nil }
            if cell.column <= column && cell.column + cell.columnSpan > column { cell.columnSpan -= 1 }
            else if cell.column > column { cell.column -= 1 }
            return cell
        }; columns -= 1; alignments.remove(at: column)
    }
    public func mergeNeighbor(at index: Int, horizontally: Bool) -> Int? {
        guard cells.indices.contains(index) else { return nil }
        let cell = cells[index]
        let row = horizontally ? cell.row : cell.row + cell.rowSpan
        let column = horizontally ? cell.column + cell.columnSpan : cell.column
        guard let neighbor = cellIndex(row: row, column: column), neighbor != index else { return nil }
        let next = cells[neighbor]
        guard next.row == row, next.column == column,
              horizontally ? next.rowSpan == cell.rowSpan : next.columnSpan == cell.columnSpan else { return nil }
        return neighbor
    }
    @discardableResult public mutating func merge(at index: Int, horizontally: Bool) -> Bool {
        guard let neighbor = mergeNeighbor(at: index, horizontally: horizontally) else { return false }
        let next = cells[neighbor]
        if !next.text.isEmpty { cells[index].text += (cells[index].text.isEmpty ? "" : "\n") + next.text }
        if horizontally { cells[index].columnSpan += next.columnSpan } else { cells[index].rowSpan += next.rowSpan }
        cells.remove(at: neighbor); return true
    }
    public mutating func split(at index: Int) {
        guard cells.indices.contains(index) else { return }
        let cell = cells[index]; cells[index].rowSpan = 1; cells[index].columnSpan = 1
        for row in cell.row..<(cell.row + cell.rowSpan) {
            for column in cell.column..<(cell.column + cell.columnSpan) where row != cell.row || column != cell.column {
                cells.append(.init(row: row, column: column, text: ""))
            }
        }
        cells.sort { ($0.row, $0.column) < ($1.row, $1.column) }
    }
    public var source: String {
        func escapedHTML(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\n", with: "<br/>")
        }
        if cells.contains(where: { $0.rowSpan > 1 || $0.columnSpan > 1 }) {
            return (["<table>"] + (0..<rows).map { row in
                "  <tr>" + cells.filter { $0.row == row }.sorted { $0.column < $1.column }.map { cell in
                    let tag = row == 0 ? "th" : "td"
                    let span = (cell.rowSpan > 1 ? " rowspan=\"\(cell.rowSpan)\"" : "") + (cell.columnSpan > 1 ? " colspan=\"\(cell.columnSpan)\"" : "")
                    return "<\(tag)\(span) align=\"\(alignments[cell.column].rawValue)\">\(escapedHTML(cell.text))</\(tag)>"
                }.joined() + "</tr>"
            } + ["</table>"]).joined(separator: "\n")
        }
        func line(_ row: Int) -> String {
            "| " + (0..<columns).map { column in
                (cellIndex(row: row, column: column).map { cells[$0].text } ?? "")
                    .replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: "<br>")
            }.joined(separator: " | ") + " |"
        }
        let delimiter = "| " + alignments.map { $0 == .center ? ":---:" : $0 == .right ? "---:" : "---" }.joined(separator: " | ") + " |"
        return ([line(0), delimiter] + (1..<rows).map(line)).joined(separator: "\n")
    }
}

public struct MarkdownTableBlock: Sendable {
    public var range: NSRange
    public var table: MarkdownTable
}
public enum MarkdownTables {
    /// Split GFM rows while preserving escaped pipes, code spans and wikilinks.
    public static func row(_ line: String) -> [String]? {
        let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.contains("|") else { return nil }
        let characters = Array(line)
        var cells: [String] = [], current = "", index = 0, code = 0, wiki = false
        while index < characters.count {
            let character = characters[index]
            if character == "\\", index + 1 < characters.count, characters[index + 1] == "|" {
                current.append("|"); index += 2; continue
            }
            if character == "`" {
                var end = index + 1; while end < characters.count && characters[end] == "`" { end += 1 }
                let length = end - index
                if code == 0 { code = length } else if code == length { code = 0 }
                current += String(characters[index..<end]); index = end; continue
            }
            if character == "[", index + 1 < characters.count, characters[index + 1] == "[" { wiki = true }
            if character == "]", index + 1 < characters.count, characters[index + 1] == "]" { wiki = false }
            if character == "|" && code == 0 && !wiki { cells.append(current); current = "" }
            else { current.append(character) }
            index += 1
        }
        cells.append(current)
        if line.first == "|" { cells.removeFirst() }
        if line.last == "|", cells.last?.isEmpty == true { cells.removeLast() }
        return cells.map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "<br>", with: "\n").replacingOccurrences(of: "<br/>", with: "\n") }
    }
    public static func blocks(in source: String) -> [MarkdownTableBlock] {
        let lines = source.components(separatedBy: "\n")
        var offsets: [Int] = [], offset = 0
        for line in lines { offsets.append(offset); offset += line.utf16.count + 1 }
        var blocks: [MarkdownTableBlock] = [], index = 0, fence: String?
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let marker = String(trimmed.prefix(3))
                if fence == nil { fence = marker } else if fence == marker { fence = nil }
                index += 1; continue
            }
            if fence != nil { index += 1; continue }
            if trimmed.lowercased().hasPrefix("<table") {
                if let last = (index..<lines.count).first(where: { lines[$0].lowercased().contains("</table>") }),
                   let table = html(lines[index...last].joined(separator: "\n")) {
                    blocks.append(.init(range: NSRange(location: offsets[index], length: offsets[last] + lines[last].utf16.count - offsets[index]), table: table))
                    index = last + 1; continue
                }
            }
            guard index + 1 < lines.count, let header = row(lines[index]), !header.isEmpty, header.count <= 128,
                  let delimiter = row(lines[index + 1]), delimiter.count == header.count,
                  delimiter.allSatisfy({ $0.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil }) else { index += 1; continue }
            var body: [[String]] = [header], last = index + 1
            while last + 1 < lines.count, let cells = row(lines[last + 1]), !lines[last + 1].trimmingCharacters(in: .whitespaces).isEmpty, body.count < 2048 {
                body.append(cells); last += 1
            }
            var table = MarkdownTable(rows: body.count, columns: header.count)
            table.alignments = delimiter.map { $0.first == ":" && $0.last == ":" ? .center : $0.last == ":" ? .right : .left }
            for i in table.cells.indices { let cell = table.cells[i]; table.cells[i].text = body[cell.row].indices.contains(cell.column) ? body[cell.row][cell.column] : "" }
            blocks.append(.init(range: NSRange(location: offsets[index], length: offsets[last] + lines[last].utf16.count - offsets[index]), table: table))
            index = last + 1
        }
        return blocks
    }
    public static func html(_ source: String) -> MarkdownTable? {
        guard !source.localizedCaseInsensitiveContains("<!DOCTYPE"), !source.localizedCaseInsensitiveContains("<!ENTITY") else { return nil }
        let delegate = TableXMLDelegate()
        let parser = XMLParser(data: Data(source.utf8)); parser.delegate = delegate; parser.shouldResolveExternalEntities = false
        guard parser.parse(), !delegate.invalid, !delegate.rows.isEmpty, delegate.rows.count <= 2048 else { return nil }
        var cells: [MarkdownTableCell] = [], occupied: Set<String> = [], columns = 0, alignments: [Int: MarkdownTable.Alignment] = [:]
        for (row, values) in delegate.rows.enumerated() {
            var column = 0
            for (index, original) in values.enumerated() {
                var cell = original
                while occupied.contains("\(row):\(column)") { column += 1 }
                guard column + cell.columnSpan <= 128, row + cell.rowSpan <= delegate.rows.count else { return nil }
                cell.row = row; cell.column = column
                for r in row..<(row + cell.rowSpan) { for c in column..<(column + cell.columnSpan) {
                    guard occupied.insert("\(r):\(c)").inserted else { return nil }
                } }
                cells.append(cell); column += cell.columnSpan; columns = max(columns, column)
                if row == 0 { for c in cell.column..<(cell.column + cell.columnSpan) { alignments[c] = delegate.alignments[row][index] } }
            }
        }
        guard columns > 0 else { return nil }
        var table = MarkdownTable(rows: delegate.rows.count, columns: columns); table.cells = cells
        table.alignments = (0..<columns).map { alignments[$0] ?? .left }
        for row in 0..<table.rows { for column in 0..<columns where table.cellIndex(row: row, column: column) == nil { table.cells.append(.init(row: row, column: column, text: "")) } }
        table.cells.sort { ($0.row, $0.column) < ($1.row, $1.column) }
        return table
    }
}
private final class TableXMLDelegate: NSObject, XMLParserDelegate {
    var rows: [[MarkdownTableCell]] = []
    var cell: MarkdownTableCell?
    var alignments: [[MarkdownTable.Alignment]] = []
    var currentAlignment = MarkdownTable.Alignment.left
    var invalid = false
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        let name = name.lowercased()
        if name == "tr" { rows.append([]); alignments.append([]) }
        else if name == "td" || name == "th" {
            let rowSpan = Int(attributes["rowspan"] ?? "1") ?? 0, columnSpan = Int(attributes["colspan"] ?? "1") ?? 0
            guard !rows.isEmpty, cell == nil, (1...128).contains(rowSpan), (1...128).contains(columnSpan) else { invalid = true; parser.abortParsing(); return }
            cell = .init(row: rows.count - 1, column: 0, text: "", rowSpan: rowSpan, columnSpan: columnSpan)
            currentAlignment = MarkdownTable.Alignment(rawValue: attributes["align"] ?? "left") ?? .left
        } else if cell != nil {
            switch name {
            case "br": cell?.text += "\n"
            case "strong", "b": cell?.text += "**"
            case "em", "i": cell?.text += "*"
            case "u": cell?.text += "<u>"
            case "code": cell?.text += "`"
            default: invalid = true; parser.abortParsing()
            }
        } else if !["table", "thead", "tbody", "tfoot"].contains(name) { invalid = true; parser.abortParsing() }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { cell?.text += string }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name.lowercased() {
        case "td", "th": if let cell, !rows.isEmpty { rows[rows.count - 1].append(cell); alignments[rows.count - 1].append(currentAlignment) }; cell = nil
        case "strong", "b": cell?.text += "**"
        case "em", "i": cell?.text += "*"
        case "u": cell?.text += "</u>"
        case "code": cell?.text += "`"
        default: break
        }
    }
}
