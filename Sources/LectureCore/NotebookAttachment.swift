import Foundation
import PDFKit
import ImageIO
import UniformTypeIdentifiers

public struct NotebookAttachment: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var notebookID: String
    public var name: String
    public var mimeType: String
    public var byteCount: Int
    public var text: String
    public var imageCount: Int
    public var isImage: Bool { mimeType.hasPrefix("image/") }
    public var isPDF: Bool { mimeType == "application/pdf" }
    public var storagePrefix: String { "projects/attachments/\(notebookID)/\(id)" }
}

public struct NotebookInputImage: Sendable {
    public var name: String
    public var data: Data
    public init(name: String, data: Data) { self.name = name; self.data = data }
}

public enum NotebookAttachmentImport {
    public static let maximumBytes = 20 * 1024 * 1024
    public static let maximumFiles = 8
    public static let maximumImages = 24
    public static func prepare(url: URL, notebookID: String, workspace: SafeWorkspace) throws -> NotebookAttachment {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true else { throw MediaError.invalid("Choose a regular file, not a folder or link.") }
        guard (info.fileSize ?? maximumBytes + 1) <= maximumBytes else { throw MediaError.invalid("Attachments must be 20 MB or smaller.") }
        return try prepare(data: Data(contentsOf: url), name: url.lastPathComponent, notebookID: notebookID, workspace: workspace)
    }
    public static func prepare(data: Data, name: String, notebookID: String, workspace: SafeWorkspace) throws -> NotebookAttachment {
        guard !data.isEmpty, data.count <= maximumBytes else { throw MediaError.invalid("Attachments must contain data and be 20 MB or smaller.") }
        guard !notebookID.contains("/"), notebookID != ".." else { throw MediaError.invalid("Invalid notebook.") }
        let ext = (name as NSString).pathExtension.lowercased()
        var images: [Data] = [], text = "", mime = "text/plain"
        if ext == "pdf" {
            mime = "application/pdf"
            guard let pdf = PDFDocument(data: data), !pdf.isLocked, pdf.pageCount > 0 else { throw MediaError.invalid("This PDF is locked or cannot be read.") }
            guard pdf.pageCount <= maximumImages else { throw MediaError.invalid("Attach a PDF with 24 pages or fewer. Split larger PDFs before attaching them.") }
            for index in 0..<pdf.pageCount {
                guard let page = pdf.page(at: index) else { throw MediaError.invalid("A PDF page could not be read.") }
                text += "\n[Page \(index + 1)]\n" + (page.string ?? "")
                let thumbnail = page.thumbnail(of: NSSize(width: 1200, height: 1600), for: .mediaBox)
                guard let tiff = thumbnail.tiffRepresentation else { throw MediaError.invalid("A PDF page could not be rendered.") }
                images.append(try imagePNG(tiff))
            }
        } else if let type = UTType(filenameExtension: ext), type.conforms(to: .image) {
            mime = type.preferredMIMEType ?? "image/png"
            images = [try imagePNG(data)]
        } else if ext == "rtf" || ext == "docx" {
            let type: NSAttributedString.DocumentType = ext == "rtf" ? .rtf : .officeOpenXML
            text = try NSAttributedString(data: data, options: [.documentType: type], documentAttributes: nil).string
            mime = ext == "rtf" ? "application/rtf" : "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        } else {
            let allowed = ["txt", "md", "markdown", "csv", "tsv", "json", "jsonl", "yaml", "yml", "xml", "html", "css", "js", "ts", "tsx", "jsx", "swift", "py", "java", "c", "h", "cpp", "rs", "go", "sh", "sql", "log", "tex", "toml"]
            guard allowed.contains(ext), let decoded = String(data: data, encoding: .utf8), !decoded.contains("\0") else {
                throw MediaError.invalid("Unsupported file type. Attach images, PDFs, DOCX, RTF, or UTF-8 text/code files. Export other documents as PDF or text first.")
            }
            text = decoded
        }
        guard text.utf8.count <= 180_000 else { throw MediaError.invalid("This file contains too much text. Split it into smaller files before attaching it.") }
        let attachment = NotebookAttachment(id: UUID().uuidString, notebookID: notebookID, name: name, mimeType: mime, byteCount: data.count, text: text, imageCount: images.count)
        try workspace.writeStorage(attachment.storagePrefix + "/original", data: data)
        for (index, image) in images.enumerated() { try workspace.writeStorage(attachment.storagePrefix + "/\(index).png", data: image) }
        return attachment
    }
    private static func imagePNG(_ data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1600, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { throw MediaError.invalid("This image cannot be read.") }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { throw MediaError.invalid("Could not prepare image.") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw MediaError.invalid("Could not prepare image.") }
        return output as Data
    }
    public static func images(_ attachments: [NotebookAttachment], notebookID: String, workspace: SafeWorkspace) throws -> [NotebookInputImage] {
        guard attachments.allSatisfy({ $0.notebookID == notebookID && UUID(uuidString: $0.id) != nil }), attachments.reduce(0, { $0 + $1.imageCount }) <= maximumImages else { throw MediaError.invalid("Attachment context exceeds 24 images/pages or belongs to another notebook. Start a new chat for more attachments.") }
        let result: [NotebookInputImage] = try attachments.flatMap { attachment in
            guard attachment.imageCount >= 0 else { throw MediaError.invalid("Invalid attachment.") }
            return try (0..<attachment.imageCount).map { index in
                NotebookInputImage(name: attachment.name + (attachment.isPDF ? " · page \(index + 1)" : ""), data: try workspace.readStorage(attachment.storagePrefix + "/\(index).png"))
            }
        }
        guard result.reduce(0, { $0 + $1.data.count }) <= 32 * 1024 * 1024 else { throw MediaError.invalid("Prepared images exceed 32 MB. Attach fewer images or PDF pages.") }
        return result
    }
}
