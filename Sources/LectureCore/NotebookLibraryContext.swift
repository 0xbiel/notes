import Foundation
import PDFKit
import UniformTypeIdentifiers

/// Reads imported sources without copying them into chat attachment storage.
public enum NotebookLibraryContext {
    public struct Content {
        public var text: String
        public var images: [NotebookInputImage]
        public var sourceDigest: String? = nil
    }
    /// Part of a long source: a page range, or the pages that mention some words.
    public enum Selection: Equatable, Sendable {
        case pages(ClosedRange<Int>)
        case find(String)
    }
    /// `readFiles` entries may end in `#pages=12-18` or `#find=words`, and reach a file inside
    /// a ZIP archive with `#entry=path/in/archive` (repeated for an archive inside an archive).
    public static func parse(_ entry: String) -> (path: String, inside: [String], selection: Selection?) {
        var whole = entry, selection: Selection?
        if let marker = entry.range(of: "#pages=", options: .backwards) {
            let bounds = entry[marker.upperBound...].split(separator: "-", omittingEmptySubsequences: false).map { Int($0.trimmingCharacters(in: .whitespaces)) }
            if let first = bounds.first ?? nil, first > 0, bounds.count <= 2, let last = bounds.count == 2 ? bounds[1] : first, last >= first { whole = String(entry[..<marker.lowerBound]); selection = .pages(first...last) }
        }
        if selection == nil, let marker = entry.range(of: "#find=", options: .backwards) {
            let words = entry[marker.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !words.isEmpty { whole = String(entry[..<marker.lowerBound]); selection = .find(words) }
        }
        let pieces = whole.components(separatedBy: "#entry=")
        guard pieces.count > 1, !pieces.contains(where: \.isEmpty) else { return (whole, [], selection) }
        return (pieces[0], Array(pieces.dropFirst()), selection)
    }
    /// A whole source up to this size is supplied at once; a longer one is read in parts.
    static let wholeLimit = 180_000, partLimit = 80_000

    /// Text of a document that is not read page by page; nil when the format has no text to extract.
    private static func plainText(_ data: Data, ext: String) throws -> String? {
        if ext == "rtf" || ext == "docx" {
            return try NSAttributedString(data: data, options: [.documentType: ext == "rtf" ? NSAttributedString.DocumentType.rtf : .officeOpenXML], documentAttributes: nil).string
        }
        if let decoded = String(data: data, encoding: .utf8), !decoded.contains("\0") { return decoded }
        return nil
    }
    /// An archive reads as one text: the list of its files, then the content of each one that has text.
    /// A long archive is cut into parts like any other long source, and every file can be requested on its own.
    private static func archiveText(_ data: Data, path: String) throws -> String {
        let archive = try ZipArchiveReader(data: data)
        var listing = "[ZIP archive with \(archive.entries.count) files. Text files follow, each under a \"[File: name]\" line. Any file can be read on its own, in full, by requesting \"\(path)#entry=name\" in readFiles; add #pages=A-B or #find=words for a long one.]\n", body = ""
        for entry in archive.entries {
            listing += "- \(entry.name) (\(entry.size) bytes)\n"
            let ext = (entry.name as NSString).pathExtension.lowercased(), alone = "request \"\(path)#entry=\(entry.name)\" in readFiles"
            var content: String
            if let type = UTType(filenameExtension: ext), type.conforms(to: .image) { content = "[Image: \(alone) to see it.]" }
            else if ext == "zip" { content = "[ZIP archive: \(alone) to list and read its files.]" }
            else {
                do {
                    let file = try archive.contents(of: entry)
                    if ext == "pdf" {
                        guard let pdf = PDFDocument(data: file), !pdf.isLocked else { throw MediaError.invalid("locked or unreadable PDF") }
                        let pages = (0..<pdf.pageCount).map { pdf.page(at: $0)?.string ?? "" }
                        content = pages.enumerated().map { "[Page \($0.offset + 1)]\n" + $0.element }.joined(separator: "\n")
                        if pages.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { content += "\n[Scanned pages: \(alone) to see them as images.]" }
                    } else { content = try plainText(file, ext: ext) ?? "[Not text: this file's content cannot be extracted.]" }
                } catch { content = "[Could not be read: \(error.localizedDescription)]" }
            }
            body += "\n[File: \(entry.name)]\n" + content + "\n"
        }
        return listing + body
    }

    public static func read(_ path: String, inside: [String] = [], selection: Selection? = nil, library: NotebookFileLibrary, notebookID: String) throws -> Content {
        try library.validate(path, notebookID: notebookID)
        _ = try library.workspace.fileURL(path)
        var data = try library.workspace.readFile(path), label = path
        let digest = NotebookSourceImage.digest(data)
        // Each step opens the archive reached so far and takes one file out of it.
        for name in inside {
            guard (label as NSString).pathExtension.lowercased() == "zip" else { throw MediaError.invalid("\(label) is not a ZIP archive.") }
            let archive = try ZipArchiveReader(data: data)
            guard let entry = archive.entry(named: name) else { throw MediaError.invalid("No file \"\(name)\" inside \(label). Request \"\(label)\" in readFiles to list its files.") }
            data = try archive.contents(of: entry); label += "#entry=" + entry.name
        }
        var result = try content(data, path: label, selection: selection)
        result.sourceDigest = digest
        return result
    }
    private static func content(_ data: Data, path: String, selection: Selection?) throws -> Content {
        let ext = (path as NSString).pathExtension.lowercased()
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
            if ext == "zip" { text = try archiveText(data, path: path) }
            else if let plain = try plainText(data, ext: ext) { text = plain }
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
            if let document {
                if images.count < NotebookAttachmentImport.maximumImages, let tiff = document.page(at: index)?.thumbnail(of: NSSize(width: 1200, height: 1600), for: .mediaBox).tiffRepresentation {
                    images.append(.init(name: path + " · page \(index + 1)", data: try NotebookAttachmentImport.imagePNG(tiff)))
                    text += "\n[Page supplied as an image, including its diagrams and figures. Image crop coordinates use a normalized top-left origin.]"
                } else { text += "\n[Scanned page omitted: 24-image limit. Request fewer pages.]" }
            }
        }
        if let first = omitted.first, let last = omitted.last, selection != nil { text += "\n[Not supplied for length: \(unit.lowercased())s \(first)–\(last). Request them separately.]" }
        return Content(text: text, images: images)
    }
}
