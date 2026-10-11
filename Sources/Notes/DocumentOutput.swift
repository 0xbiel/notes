import AppKit
import PDFKit
import UniformTypeIdentifiers
import LectureCore

@MainActor enum DocumentOutput {
    static let printableExtensions: Set<String> = ["md", "tex", "pdf", "docx", "rtf", "txt", "png", "jpg", "jpeg", "heic", "gif", "webp", "tiff", "tif"]

    static func markdownView(_ source: String, directory: URL, root: URL) -> MarkdownTextView {
        let view = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 515, height: 100))
        view.appearance = NSAppearance(named: .aqua)
        view.liveEditing = false
        view.isEditable = false
        view.imageDirectory = directory
        view.imageRoot = root
        view.string = source
        view.appearance?.performAsCurrentDrawingAppearance { view.renderMarkdown() }
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        view.sizeToFit()
        return view
    }

    static func printInfo() -> NSPrintInfo {
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 595.28, height: 841.89)
        info.topMargin = 36; info.bottomMargin = 36
        info.leftMargin = 40; info.rightMargin = 40
        info.isHorizontallyCentered = false; info.isVerticallyCentered = false
        info.horizontalPagination = .fit; info.verticalPagination = .automatic
        return info
    }

    static func markdownPDF(_ source: String, directory: URL, root: URL) throws -> Data {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let info = printInfo()
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = temporary
        let operation = NSPrintOperation(view: markdownView(source, directory: directory, root: root), printInfo: info)
        operation.showsPrintPanel = false; operation.showsProgressPanel = false
        guard operation.run(), let document = PDFDocument(url: temporary), document.pageCount > 0 else {
            throw MediaError.invalid("Unable to generate the rendered PDF.")
        }
        return try Data(contentsOf: temporary)
    }

    static func printPDF(_ document: PDFDocument) throws {
        guard let operation = document.printOperation(for: printInfo(), scalingMode: .pageScaleDownToFit, autoRotate: true) else {
            throw MediaError.invalid("Unable to print this PDF.")
        }
        operation.showsPrintPanel = true; operation.run()
    }

    static func printFile(_ url: URL) throws {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            guard let document = PDFDocument(url: url) else { throw MediaError.invalid("Invalid PDF.") }
            try printPDF(document)
        } else if ["docx", "rtf", "txt"].contains(ext) {
            let options: [NSAttributedString.DocumentReadingOptionKey: Any] = ext == "docx" ? [.documentType: NSAttributedString.DocumentType.officeOpenXML] : ext == "rtf" ? [.documentType: NSAttributedString.DocumentType.rtf] : [.documentType: NSAttributedString.DocumentType.plain]
            let text = try NSAttributedString(url: url, options: options, documentAttributes: nil)
            let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 515, height: 100))
            view.textStorage?.setAttributedString(text); view.isEditable = false
            view.isVerticallyResizable = true; view.sizeToFit()
            NSPrintOperation(view: view, printInfo: printInfo()).run()
        } else {
            guard printableExtensions.contains(ext), let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else {
                throw MediaError.invalid("This file cannot be printed.")
            }
            let view = NSImageView(frame: NSRect(x: 0, y: 0, width: 515, height: 770))
            view.image = image; view.imageScaling = .scaleProportionallyUpOrDown
            NSPrintOperation(view: view, printInfo: printInfo()).run()
        }
    }
}

@MainActor extension Workbench {
    var canPrintDocument: Bool {
        selectedLibraryPath.map { DocumentOutput.printableExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) } ?? false
    }
    func exportSelectedPDF() {
        guard let path = selectedLibraryPath, let workspace else { return }
        let snapshot = draftText
        let root = workspace.courseRoot.appendingPathComponent(currentNotebook.rootPrefix)
        let panel = NSSavePanel(); panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent + ".pdf"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            Task { @MainActor in
                do {
                    let data: Data
                    if LaTeXDocument.isSource(path) { data = try await self.latexController(path).compile() }
                    else if path.hasSuffix(".md") {
                        data = try DocumentOutput.markdownPDF(snapshot, directory: try workspace.fileURL(path).deletingLastPathComponent(), root: root)
                    } else { throw MediaError.invalid("Select the document again before exporting.") }
                    try data.write(to: url, options: .atomic)
                    self.statusText = "PDF: " + url.lastPathComponent
                } catch { self.errorText = error.localizedDescription }
            }
        }
    }
    func printSelectedDocument() {
        guard let path = selectedLibraryPath, let workspace else { return }
        Task { @MainActor in
            do {
                if LaTeXDocument.isSource(path) {
                    let data = try await latexController(path).compile()
                    guard let document = PDFDocument(data: data) else { throw MediaError.invalid("Invalid compiled PDF.") }
                    try DocumentOutput.printPDF(document)
                } else if path == selectedNote {
                    let view = DocumentOutput.markdownView(draftText, directory: try workspace.fileURL(path).deletingLastPathComponent(), root: workspace.courseRoot.appendingPathComponent(currentNotebook.rootPrefix))
                    NSPrintOperation(view: view, printInfo: DocumentOutput.printInfo()).run()
                } else { try DocumentOutput.printFile(workspace.fileURL(path)) }
            } catch { errorText = error.localizedDescription }
        }
    }
}
