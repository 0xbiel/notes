import Foundation
import UniformTypeIdentifiers

/// Binary library files stay outside Markdown editing and assistant transactions.
public struct NotebookFileTransfer {
    public var files: [String: Data]
    public var folders: [String]
    public init(files: [String: Data], folders: [String] = []) { self.files = files; self.folders = folders }
}

public final class NotebookFileLibrary {
    public let projects: NotebookProjectStore
    public var workspace: SafeWorkspace { projects.workspace }
    public init(projects: NotebookProjectStore) { self.projects = projects }

    public func validate(_ path: String, notebookID: String) throws {
        _ = try workspace.fileURL(path)
        guard projects.owner(of: path)?.id == notebookID,
              projects.notebooks.contains(where: { $0.id == notebookID && $0.archivedAt == nil }) else { throw ReplayError.unsafePath(path) }
    }
    public func snapshot(notebookID: String, path: String? = nil, folder: Bool = false) throws -> NotebookFileTransfer {
        let files = try workspace.fileNames().filter {
            projects.owner(of: $0)?.id == notebookID && (path == nil || (folder ? $0.hasPrefix(path! + "/") : $0 == path!))
        }
        if let path { try validate(folder ? path + "/placeholder" : path, notebookID: notebookID) }
        let directories: [String]
        if let path, folder {
            guard !projects.notebooks.contains(where: { !$0.rootPrefix.isEmpty && ($0.rootPrefix == path || $0.rootPrefix.hasPrefix(path + "/")) }) else { throw ReplayError.unsafePath(path) }
            directories = try workspace.libraryFolderTree(path)
        }
        else if path == nil { directories = try workspace.folderNames().filter { $0 != "Cuadernos" && projects.owner(of: $0 + "/placeholder")?.id == notebookID } }
        else { directories = [] }
        return try .init(files: Dictionary(uniqueKeysWithValues: files.map { ($0, try workspace.readFile($0)) }), folders: directories)
    }
    public func availablePath(_ proposed: String, reserved: Set<String> = []) throws -> String {
        _ = try workspace.fileURL(proposed + "/placeholder") // Works for files and folders, including a colliding directory.
        let names = Set((try workspace.fileNames() + workspace.folderNames()).map { $0.precomposedStringWithCanonicalMapping.lowercased() }).union(reserved.map { $0.precomposedStringWithCanonicalMapping.lowercased() })
        let url = URL(fileURLWithPath: proposed)
        let suffix = url.pathExtension.isEmpty ? "" : "." + url.pathExtension
        let stem = suffix.isEmpty ? proposed : String(proposed.dropLast(suffix.count))
        var candidate = proposed, index = 1
        while names.contains(candidate.precomposedStringWithCanonicalMapping.lowercased()) {
            candidate = stem + " copy" + (index == 1 ? "" : " \(index)") + suffix; index += 1
        }
        return candidate
    }
    public func externalSnapshot(_ url: URL, destination: String) throws -> NotebookFileTransfer {
        guard url.isFileURL else { throw ReplayError.unsafePath(url.absoluteString) }
        let fm = FileManager.default
        let attributes = try fm.attributesOfItem(atPath: url.path)
        let type = attributes[.type] as? FileAttributeType
        guard type == .typeRegular || type == .typeDirectory else { throw ReplayError.unsafePath(url.path) }
        if type == .typeRegular {
            try Self.validateImportType(url)
            return .init(files: [destination: try Data(contentsOf: url)])
        }
        var files: [String: Data] = [:], folders = [destination]
        guard let iterator = fm.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { throw ReplayError.unsafePath(url.path) }
        for case let child as URL in iterator {
            let name = destination + "/" + String(child.path.dropFirst(url.path.count + 1))
            let kind = try fm.attributesOfItem(atPath: child.path)[.type] as? FileAttributeType
            if kind == .typeDirectory { folders.append(name) }
            else if kind == .typeRegular { try Self.validateImportType(child); files[name] = try Data(contentsOf: child) }
            else { throw ReplayError.unsafePath(child.path) }
        }
        return .init(files: files, folders: folders)
    }
    private static func validateImportType(_ url: URL) throws {
        let ext = url.pathExtension.lowercased()
        let type = UTType(filenameExtension: ext)
        let mediaExtensions: Set<String> = ["mp3", "wav", "m4a", "aac", "flac", "ogg", "opus", "aiff", "aif", "caf", "mp4", "m4v", "mov", "avi", "mkv", "webm"]
        guard type?.conforms(to: .audio) != true, type?.conforms(to: .movie) != true, !mediaExtensions.contains(ext) else {
            throw MediaError.invalid("No se importan archivos de audio o vídeo. Usa el micrófono para dictar en el chat.")
        }
    }
    public func write(_ transfer: NotebookFileTransfer, notebookID: String, summary: String) throws {
        let fm = FileManager.default
        var directories = Set(transfer.folders)
        for folder in transfer.folders { try validate(folder + "/placeholder", notebookID: notebookID) }
        for path in Array(transfer.files.keys) + transfer.folders {
            let parts = path.components(separatedBy: "/")
            for length in 1..<parts.count { directories.insert(parts.prefix(length).joined(separator: "/")) }
        }
        for path in transfer.files.keys {
            try validate(path, notebookID: notebookID)
            guard !fm.fileExists(atPath: try workspace.fileURL(path).path) else { throw ReplayError.conflict }
        }
        for directory in directories { _ = try workspace.fileURL(directory + "/placeholder") }
        let markdown = try transfer.files.keys.sorted().filter { $0.hasSuffix(".md") }.map { path in
            guard let text = String(data: transfer.files[path]!, encoding: .utf8) else { throw ReplayError.invalidResponse("El archivo Markdown no usa UTF-8: " + path) }
            return NotebookFileChange(path: path, before: nil, after: text)
        }
        var createdFolders: [String] = [], createdAssets: [String] = []
        do {
            for directory in directories.sorted(by: { $0.count < $1.count }) {
                let url = try workspace.fileURL(directory + "/placeholder").deletingLastPathComponent()
                if !fm.fileExists(atPath: url.path) { try workspace.createFolder(directory); createdFolders.append(directory) }
            }
            for path in transfer.files.keys.sorted() where !path.hasSuffix(".md") {
                try workspace.createAsset(path, data: transfer.files[path]!); createdAssets.append(path)
            }
            if !markdown.isEmpty { _ = try projects.apply(notebookID, summary: summary, changes: markdown) }
        } catch {
            for path in createdAssets.reversed() { try? workspace.removeAsset(path, expected: transfer.files[path]!) }
            for directory in createdFolders.reversed() { try? workspace.removeEmptyFolder(directory) }
            throw error
        }
    }
}
