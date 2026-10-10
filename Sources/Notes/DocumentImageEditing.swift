import AppKit
import ImageIO
import UniformTypeIdentifiers
import LectureCore

struct DocumentImagePresentation: Codable {
    static let pasteboardType = NSPasteboard.PasteboardType("local.palladium.document-image")
    var sourceURL: String
    var width: Double?
    var crop: [Double]
    var metadata: String? {
        guard crop.count == 4, crop.allSatisfy({ $0.isFinite }), crop[0] >= 0, crop[1] >= 0, crop[2] >= 0.02, crop[3] >= 0.02, crop[0] + crop[2] <= 1.00001, crop[1] + crop[3] <= 1.00001 else { return nil }
        var fields: [String] = []
        if let width { guard width.isFinite, (48...2000).contains(width) else { return nil }; fields.append("width=" + String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), width)) }
        if crop != [0, 0, 1, 1] { fields.append("crop=" + crop.map { String(format: "%.5f", locale: Locale(identifier: "en_US_POSIX"), $0) }.joined(separator: ",")) }
        return fields.isEmpty ? "" : " <!-- palladium-image " + fields.joined(separator: ";") + " -->"
    }
}
struct DocumentImageInput {
    let data: Data
    let fileExtension: String
    var presentation: DocumentImagePresentation? = nil
    static func validated(_ data: Data) throws -> DocumentImageInput {
        guard data.count <= 20_000_000, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source), let uti = UTType(type as String),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0, w <= 12_000, h <= 12_000, w * h <= 40_000_000,
              CGImageSourceGetCount(source) <= 500, w * h * CGImageSourceGetCount(source) <= 100_000_000 else { throw MediaError.invalid("This image exceeds the supported size or animation limits.") }
        if [UTType.png, .jpeg, .gif, .webP].contains(where: { uti.conforms(to: $0) }) { return .init(data: data, fileExtension: uti.preferredFilenameExtension ?? "png") }
        guard let bitmap = NSBitmapImageRep(data: data), let png = bitmap.representation(using: .png, properties: [:]) else { throw MediaError.invalid("This image format cannot be inserted.") }
        return .init(data: png, fileExtension: "png")
    }
    @MainActor static func read(_ board: NSPasteboard) throws -> [DocumentImageInput] {
        let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let presentation = board.data(forType: DocumentImagePresentation.pasteboardType).flatMap { $0.count <= 4096 ? try? JSONDecoder().decode(DocumentImagePresentation.self, from: $0) : nil }
        if !urls.isEmpty {
            return try urls.prefix(8).compactMap { url in
                guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) else { return nil }
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values.isRegularFile == true, let size = values.fileSize, size <= 20_000_000 else { throw MediaError.invalid("Image is too large.") }
                var input = try validated(Data(contentsOf: url))
                if presentation?.sourceURL == url.absoluteString { input.presentation = presentation }
                return input
            }
        }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = board.data(forType: type) { return [try validated(data)] }
        }
        return []
    }
    @MainActor static func containsImage(_ board: NSPasteboard) -> Bool {
        if board.availableType(from: [.png, .tiff]) != nil { return true }
        return (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []).contains { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
    }
}

@MainActor extension MarkdownTextView {
    @discardableResult func insertImages(from board: NSPasteboard, at position: Int? = nil) -> Bool {
        guard isEditable, !hasMarkedText(), let importImage, let imageDirectory else { return false }
        do {
            let images = try DocumentImageInput.read(board)
            guard !images.isEmpty else { return false }
            var snippets: [String] = []
            for image in images {
                let url = try importImage(image.data, image.fileExtension)
                let directory = imageDirectory.standardizedFileURL.pathComponents, target = url.standardizedFileURL.pathComponents
                var common = 0
                while common < min(directory.count, target.count), directory[common] == target[common] { common += 1 }
                let path = (Array(repeating: "..", count: directory.count - common) + target.dropFirst(common)).joined(separator: "/")
                let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "()#?"))) ?? path
                snippets.append("![Image](\(encoded))" + (image.presentation?.metadata ?? ""))
            }
            selectedImageLocation = nil
            let range = position.map { NSRange(location: min(max(0, $0), string.utf16.count), length: 0) } ?? selectedRange()
            replaceImageText("\n\n" + snippets.joined(separator: "\n\n") + "\n\n", range: range)
            renderMarkdown()
            if let last = renderedImages.last(where: { $0.range.location >= range.location }) { selectImage(at: last.range.location) }
            return true
        } catch { showImageError(error); return true }
    }
    private func replaceImageText(_ text: String, range: NSRange) {
        breakUndoCoalescing()
        guard let undoManager else { insertText(text, replacementRange: range); return }
        // Each object operation is one undo step, separate from surrounding typing.
        if undoManager.groupsByEvent, undoManager.groupingLevel == 1 { undoManager.endUndoGrouping() }
        let byEvent = undoManager.groupsByEvent; undoManager.groupsByEvent = false
        undoManager.beginUndoGrouping(); insertText(text, replacementRange: range); undoManager.endUndoGrouping()
        undoManager.groupsByEvent = byEvent; breakUndoCoalescing()
    }
    func showImageError(_ error: Error) {
        let alert = NSAlert(); alert.messageText = UserDefaults.standard.string(forKey: "notes.language") == "en" ? "Could not insert image" : "No se pudo insertar la imagen"
        alert.informativeText = error.localizedDescription
        if let window { alert.beginSheetModal(for: window) }
    }
    func selectImage(at location: Int) {
        selectedImageLocation = location; window?.makeFirstResponder(self); updateImageSelection()
    }
    func changeImage(at location: Int, width: CGFloat?, crop: NSRect) {
        guard isEditable, let image = renderedImages.first(where: { $0.range.location == location }) else { return }
        let full = NSRect(x: 0, y: 0, width: 1, height: 1)
        let metadata: String
        if width == nil && crop == full { metadata = "" }
        else {
            var fields: [String] = []
            if let width { fields.append("width=" + String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), width)) }
            if crop != full { fields.append("crop=" + [crop.minX, crop.minY, crop.width, crop.height].map { String(format: "%.5f", locale: Locale(identifier: "en_US_POSIX"), $0) }.joined(separator: ",")) }
            metadata = " <!-- palladium-image " + fields.joined(separator: ";") + " -->"
        }
        replaceImageText(image.markdown + metadata, range: image.range)
        selectedImageLocation = location; renderMarkdown(); updateImageSelection()
    }
    func removeSelectedImage() {
        guard isEditable, let location = selectedImageLocation, let image = renderedImages.first(where: { $0.range.location == location }) else { return }
        selectedImageLocation = nil; replaceImageText("", range: image.range); renderMarkdown()
    }
    func copySelectedImage() {
        guard let location = selectedImageLocation, let image = renderedImages.first(where: { $0.range.location == location }), let data = try? Data(contentsOf: image.url) else { return }
        let board = NSPasteboard.general; board.clearContents()
        board.writeObjects([image.url as NSURL])
        let presentation = DocumentImagePresentation(sourceURL: image.url.absoluteString, width: image.requestedWidth.map(Double.init), crop: [image.crop.minX, image.crop.minY, image.crop.width, image.crop.height].map(Double.init))
        if let encoded = try? JSONEncoder().encode(presentation) { board.setData(encoded, forType: DocumentImagePresentation.pasteboardType) }
        // Standard image data also supports pasting into other applications.
        if image.url.pathExtension == "png" { board.setData(data, forType: .png) }
        else if let tiff = image.image.tiffRepresentation { board.setData(tiff, forType: .tiff) }
    }
}

@MainActor extension Workbench {
    func importDocumentImage(_ data: Data, fileExtension: String, note: String) throws -> URL {
        guard canManageFiles, selectedNote == note, let workspace, let projects, projects.owner(of: note)?.id == currentNotebook.id else { throw ReplayError.conflict }
        let image = try DocumentImageInput.validated(data)
        let prefix = currentNotebook.rootPrefix.isEmpty ? "" : currentNotebook.rootPrefix + "/"
        let path = prefix + ".palladium-images/image-" + UUID().uuidString.lowercased() + "." + image.fileExtension
        try workspace.createAsset(path, data: image.data)
        try refreshCreationLocations()
        return try workspace.fileURL(path)
    }
}
