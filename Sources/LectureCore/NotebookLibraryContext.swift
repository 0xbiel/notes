import Foundation
import PDFKit
import UniformTypeIdentifiers

/// Reads imported sources without copying them into chat attachment storage.
public enum NotebookLibraryContext {
    public struct Content {
        public var text: String
        public var images: [NotebookInputImage]
    }
    /// Part of a long source: a page range, or the pages that mention some words.
    public enum Selection: Equatable, Sendable {
        case pages(ClosedRange<Int>)
        case find(String)
    }
    /// `readFiles` entries may end in `#pages=12-18` or `#find=words`.
    public static func parse(_ entry: String) -> (path: String, selection: Selection?) {
        if let marker = entry.range(of: "#pages=", options: .backwards) {
            let bounds = entry[marker.upperBound...].split(separator: "-", omittingEmptySubsequences: false).map { Int($0.trimmingCharacters(in: .whitespaces)) }
            if let first = bounds.first ?? nil, first > 0, bounds.count <= 2, let last = bounds.count == 2 ? bounds[1] : first, last >= first { return (String(entry[..<marker.lowerBound]), .pages(first...last)) }
        }
        if let marker = entry.range(of: "#find=", options: .backwards) {
            let words = entry[marker.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !words.isEmpty { return (String(entry[..<marker.lowerBound]), .find(words)) }
        }
        return (entry, nil)
    }
    /// A whole source up to this size is supplied at once; a longer one is read in parts.
    static let wholeLimit = 180_000, partLimit = 80_000

    public static func read(_ path: String, selection: Selection? = nil, library: NotebookFileLibrary, notebookID: String) throws -> Content {
        try library.validate(path, notebookID: notebookID)
        let url = try library.workspace.fileURL(path)
        let data = try library.workspace.readFile(path)
        let ext = url.pathExtension.lowercased()
        // Pages of a PDF; other text is cut into parts of similar size so a long file can be read the same way.
        var pages: [String] = []
        var document: PDFDocument?
        if ext == "pdf" {
            guard let pdf = PDFDocument(data: data), !pdf.isLocked else { throw MediaError.invalid("Imported PDF is locked or unreadable.") }
            document = pdf
            pages = (0..<pdf.pageCount).map { pdf.page(at: $0)?.string ?? "" }
        } else if let type = UTType(filenameExtension: ext), type.conforms(to: .image) {
            return Content(text: "[Imported image supplied for visual reading.]", images: [.init(name: path, data: try NotebookAttachmentImport.imagePNG(data))])
        } else {
            let text: String
            if ext == "rtf" || ext == "docx" {
                text = try NSAttributedString(data: data, options: [.documentType: ext == "rtf" ? NSAttributedString.DocumentType.rtf : .officeOpenXML], documentAttributes: nil).string
            } else if let decoded = String(data: data, encoding: .utf8), !decoded.contains("\0") { text = decoded }
            else { throw MediaError.invalid("This imported format cannot be extracted. Export it as PDF or text.") }
            if selection == nil, text.utf8.count <= wholeLimit { return Content(text: text, images: []) }
            var rest = Substring(text)
            while !rest.isEmpty { pages.append(String(rest.prefix(4_000))); rest = rest.dropFirst(4_000) }
        }
        let unit = document == nil ? "Part" : "Page"
        let guide = "This source has \(pages.count) \(unit.lowercased())s. To read more, request \"\(path)#pages=A-B\" or \"\(path)#find=words to look for\" in readFiles."
        var chosen: [Int], note = ""
        switch selection {
        case nil:
            chosen = Array(pages.indices)
            if pages.reduce(0, { $0 + $1.utf8.count }) > wholeLimit { note = "[Source too long to supply whole: only its beginning follows. " + guide + "]" }
        case .pages(let range):
            chosen = Array(pages.indices).filter { range.contains($0 + 1) }
            guard !chosen.isEmpty else { throw MediaError.invalid("No such pages. " + guide) }
        case .find(let words):
            func fold(_ text: String) -> String { text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            let needle = fold(words)
            chosen = pages.indices.filter { fold(pages[$0]).contains(needle) }
            guard !chosen.isEmpty else { return Content(text: "[\"\(words)\" does not appear in this source. Try other words. " + guide + "]", images: []) }
            // A phrase often starts at the foot of one page and continues on the next.
            chosen = Array(Set(chosen.flatMap { [$0, $0 + 1] }).filter { $0 < pages.count }).sorted()
            note = "[\(unit)s mentioning \"\(words)\", each with the one after it. " + guide + "]"
        }
        let limit = selection == nil && note.isEmpty ? wholeLimit : partLimit
        var text = note, images: [NotebookInputImage] = [], omitted: [Int] = []
        for index in chosen {
            let page = pages[index]
            guard omitted.isEmpty, text.utf8.count + page.utf8.count <= limit || text.utf8.count == note.utf8.count else { omitted.append(index + 1); continue }
            text += "\n[\(unit) \(index + 1)]\n" + page
            if let document, page.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if images.count < NotebookAttachmentImport.maximumImages, let tiff = document.page(at: index)?.thumbnail(of: NSSize(width: 1200, height: 1600), for: .mediaBox).tiffRepresentation {
                    images.append(.init(name: path + " · page \(index + 1)", data: try NotebookAttachmentImport.imagePNG(tiff)))
                    text += "\n[Scanned page supplied as an image.]"
                } else { text += "\n[Scanned page omitted: 24-image limit. Request fewer pages.]" }
            }
        }
        if let first = omitted.first, let last = omitted.last, selection != nil { text += "\n[Not supplied for length: \(unit.lowercased())s \(first)–\(last). Request them separately.]" }
        return Content(text: text, images: images)
    }
}
