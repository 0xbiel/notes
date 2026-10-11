import Foundation
import LectureCore

@MainActor enum NotebookDocumentOutputWriter {
    static func prepare(_ outputs: [NotebookDocumentOutput], documents: [String: String], changes: [NotebookFileChange], store: NotebookProjectStore, notebook: Notebook) throws -> [(String, Data)] {
        guard outputs.count <= 10 else { throw MediaError.invalid("Too many document exports.") }
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
                guard output.path.hasSuffix(".pdf"), output.source.isEmpty, output.sourcePath.hasSuffix(".md"), let source = sources[output.sourcePath] else {
                    throw MediaError.invalid("PDF export requires a read Markdown source and a new .pdf destination.")
                }
                try store.validate(output.sourcePath, notebookID: notebook.id)
                if !changes.contains(where: { $0.path == output.sourcePath }) {
                    guard try store.workspace.readNote(output.sourcePath) == source else { throw ReplayError.conflict }
                }
                return (output.path, try DocumentOutput.markdownPDF(source, directory: try store.workspace.fileURL(output.sourcePath).deletingLastPathComponent(), root: store.workspace.courseRoot.appendingPathComponent(notebook.rootPrefix)))
            case "latex":
                guard output.path.hasSuffix(".tex"), output.sourcePath.isEmpty, !output.source.isEmpty, output.source.utf8.count <= 1_000_000 else {
                    throw MediaError.invalid("LaTeX output requires complete source and a new .tex destination.")
                }
                return (output.path, Data(output.source.utf8))
            default: throw MediaError.invalid("Unsupported document output format.")
            }
        }
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
