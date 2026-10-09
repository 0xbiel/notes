import Foundation
import PDFKit
import UniformTypeIdentifiers

/// Reads imported sources without copying them into chat attachment storage.
public enum NotebookLibraryContext {
    public struct Content {
        public var text: String
        public var images: [NotebookInputImage]
    }
    public static func read(_ path: String, library: NotebookFileLibrary, notebookID: String) throws -> Content {
        try library.validate(path, notebookID: notebookID)
        let url = try library.workspace.fileURL(path)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= 50 * 1024 * 1024 else { throw MediaError.invalid("Imported source exceeds the 50 MB reading limit. Use a smaller excerpt.") }
        let data = try library.workspace.readFile(path)
        let ext = url.pathExtension.lowercased()
        var text = "", images: [NotebookInputImage] = []
        if ext == "pdf" {
            guard let pdf = PDFDocument(data: data), !pdf.isLocked else { throw MediaError.invalid("Imported PDF is locked or unreadable.") }
            for index in 0..<pdf.pageCount {
                guard let page = pdf.page(at: index) else { continue }
                let pageText = page.string ?? ""
                text += "\n[Page \(index + 1)]\n" + pageText
                if pageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if images.count < NotebookAttachmentImport.maximumImages,
                       let tiff = page.thumbnail(of: NSSize(width: 1200, height: 1600), for: .mediaBox).tiffRepresentation {
                        images.append(.init(name: path + " · page \(index + 1)", data: try NotebookAttachmentImport.imagePNG(tiff)))
                        text += "\n[Scanned page supplied as an image.]"
                    } else { text += "\n[Scanned page omitted: 24-image limit. Request a smaller PDF excerpt.]" }
                }
                if text.utf8.count > 180_000 { text = String(text.prefix(40_000)) + "\n[Source truncated: text limit reached; remaining pages are not supplied. Ask for a smaller excerpt.]"; break }
            }
        } else if let type = UTType(filenameExtension: ext), type.conforms(to: .image) {
            images = [.init(name: path, data: try NotebookAttachmentImport.imagePNG(data))]
            text = "[Imported image supplied for visual reading.]"
        } else if ext == "rtf" || ext == "docx" {
            let type: NSAttributedString.DocumentType = ext == "rtf" ? .rtf : .officeOpenXML
            text = try NSAttributedString(data: data, options: [.documentType: type], documentAttributes: nil).string
        } else if let decoded = String(data: data, encoding: .utf8), !decoded.contains("\0") {
            text = decoded
        } else { throw MediaError.invalid("This imported format cannot be extracted. Export it as PDF or text.") }
        if text.utf8.count > 180_000 { text = String(text.prefix(40_000)) + "\n[Source truncated: text limit reached. Ask for a smaller excerpt.]" }
        return Content(text: text, images: images)
    }
}
