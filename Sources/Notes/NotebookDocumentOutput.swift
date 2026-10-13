import Foundation
import LectureCore

@MainActor enum NotebookDocumentOutputWriter {
    static func prepare(_ outputs: [NotebookDocumentOutput], documents: [String: String], changes: [NotebookFileChange], store: NotebookProjectStore, notebook: Notebook, sourceDigests: [String: String] = [:], attachments: [NotebookAttachment] = []) throws -> [(String, Data)] {
        var sources = documents
        for change in changes { sources[change.path] = change.after }
        var paths = Set<String>()
        return try outputs.map { output in
            try NotebookFileLibrary(projects: store).validate(output.path, notebookID: notebook.id)
            let url = try store.workspace.fileURL(output.path)
            guard paths.insert(output.path.precomposedStringWithCanonicalMapping.lowercased()).inserted,
                  !FileManager.default.fileExists(atPath: url.path), !changes.contains(where: { $0.path == output.path }) else { throw ReplayError.conflict }
            switch output.format {
            case "pdf":
                guard output.page == nil, output.crop == nil, output.test == nil, output.path.hasSuffix(".pdf"), output.source.isEmpty, output.sourcePath.hasSuffix(".md"), let source = sources[output.sourcePath] else {
                    throw MediaError.invalid("PDF export requires a read Markdown source and a new .pdf destination.")
                }
                try store.validate(output.sourcePath, notebookID: notebook.id)
                if !changes.contains(where: { $0.path == output.sourcePath }) {
                    guard try store.workspace.readNote(output.sourcePath) == source else { throw ReplayError.conflict }
                }
                return (output.path, try DocumentOutput.markdownPDF(source, directory: try store.workspace.fileURL(output.sourcePath).deletingLastPathComponent(), root: store.workspace.courseRoot.appendingPathComponent(notebook.rootPrefix)))
            case "latex":
                guard output.page == nil, output.crop == nil, output.test == nil, output.path.hasSuffix(".tex"), output.sourcePath.isEmpty, !output.source.isEmpty else {
                    throw MediaError.invalid("LaTeX output requires complete source and a new .tex destination.")
                }
                return (output.path, Data(output.source.utf8))
            case "image":
                guard output.path.hasSuffix(".png"), output.source.isEmpty, output.test == nil else {
                    throw MediaError.invalid("Image extraction requires a new .png destination and a read image/PDF source.")
                }
                let source = try imageSource(output.sourcePath, documents: documents, sourceDigests: sourceDigests, attachments: attachments, store: store, notebook: notebook)
                return (output.path, try NotebookSourceImage.png(source.data, filename: source.name, page: output.page, crop: output.crop))
            case "quiz":
                guard output.path.hasSuffix(".quiz.json"), output.sourcePath.isEmpty, output.source.isEmpty,
                      output.page == nil, output.crop == nil, let test = output.test else {
                    throw MediaError.invalid("A practice test requires a new .quiz.json destination and structured test content.")
                }
                try test.validate()
                for image in test.questions.flatMap({ $0.images ?? [] }) {
                    let imageURL = try NotebookPracticeTest.referenceImageURL(image, directory: url.deletingLastPathComponent(), root: store.workspace.courseRoot.appendingPathComponent(notebook.rootPrefix))
                    let imagePath = String(imageURL.path.dropFirst(store.workspace.courseRoot.path.count + 1))
                    try NotebookFileLibrary(projects: store).validate(imagePath, notebookID: notebook.id)
                    _ = try NotebookSourceImage.png(Data(contentsOf: imageURL), filename: imageURL.lastPathComponent)
                }
                return (output.path, try test.encoded())
            default: throw MediaError.invalid("Unsupported document output format.")
            }
        }
    }
    private static func imageSource(_ path: String, documents: [String: String], sourceDigests: [String: String], attachments: [NotebookAttachment], store: NotebookProjectStore, notebook: Notebook) throws -> (data: Data, name: String) {
        if path.hasPrefix("attachment:") {
            let id = String(path.dropFirst("attachment:".count))
            guard let attachment = attachments.first(where: { $0.id == id && $0.notebookID == notebook.id }), attachment.isImage || attachment.isPDF else {
                throw MediaError.invalid("The requested image/PDF attachment does not belong to this conversation.")
            }
            let data = try store.workspace.readStorage(attachment.storagePrefix + "/original")
            guard sourceDigests[path] == NotebookSourceImage.digest(data) else { throw ReplayError.conflict }
            return (data, attachment.name)
        }
        let parsed = NotebookLibraryContext.parse(path)
        guard parsed.selection == nil,
              documents.keys.contains(where: { let read = NotebookLibraryContext.parse($0); return read.path == parsed.path && read.inside == parsed.inside }) else {
            throw MediaError.invalid("Read the image/PDF source before extracting a figure.")
        }
        try NotebookFileLibrary(projects: store).validate(parsed.path, notebookID: notebook.id)
        var data = try store.workspace.readFile(parsed.path), name = parsed.path
        guard sourceDigests[parsed.path] == NotebookSourceImage.digest(data) else { throw ReplayError.conflict }
        for entry in parsed.inside {
            guard (name as NSString).pathExtension.lowercased() == "zip" else { throw MediaError.invalid("Image source is not a ZIP archive.") }
            let archive = try ZipArchiveReader(data: data)
            guard let selected = archive.entry(named: entry) else { throw MediaError.invalid("The archive image/PDF no longer exists.") }
            data = try archive.contents(of: selected); name = selected.name
        }
        return (data, name)
    }
    static func rollback(_ prepared: [(String, Data)], workspace: SafeWorkspace) throws {
        for (path, data) in prepared.reversed() { try workspace.permanentlyRemoveFile(path, expected: data) }
    }
    static func publish(_ prepared: [(String, Data)], workspace: SafeWorkspace) throws {
        var created: [(String, Data)] = []
        do {
            for (path, data) in prepared { try workspace.createAsset(path, data: data); created.append((path, data)) }
        } catch {
            for (path, data) in created.reversed() { try? workspace.permanentlyRemoveFile(path, expected: data) }
            throw error
        }
    }
}
