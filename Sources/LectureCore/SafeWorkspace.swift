import Foundation

public final class SafeWorkspace {
    public let root: URL
    public let courseRoot: URL
    public let storageRoot: URL
    public let originalRoot: URL
    private let fm = FileManager.default
    public var noteMutation: ((String, String?, String?) throws -> Bool)?

    public init(root: URL, originalRoot: URL) throws {
        self.root = root.standardizedFileURL
        self.originalRoot = originalRoot.standardizedFileURL.resolvingSymlinksInPath()
        courseRoot = self.root.appendingPathComponent("copied-course", isDirectory: true)
        storageRoot = self.root.appendingPathComponent("session-storage", isDirectory: true)
        try rejectLinks(self.root)
        guard !inside(self.root.resolvingSymlinksInPath(), self.originalRoot),
              self.root.resolvingSymlinksInPath() != self.originalRoot else {
            throw ReplayError.unsafePath(root.path)
        }
        try rejectLinks(courseRoot)
    }

    private func inside(_ child: URL, _ parent: URL) -> Bool {
        child.path.hasPrefix(parent.path + "/")
    }

    private func rejectLinks(_ path: URL) throws {
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        // /tmp and /var are system symlinks on macOS: they are resolved before
        // being used as test roots. App/workspace components themselves cannot be links.
        for component in path.pathComponents.dropFirst() {
            current.appendPathComponent(component)
            if let attributes = try? fm.attributesOfItem(atPath: current.path),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw ReplayError.unsafePath(current.path)
            }
        }
    }

    public func validated(_ path: URL, under allowedRoot: URL) throws -> URL {
        let lexical = path.standardizedFileURL
        guard lexical != allowedRoot, inside(lexical, allowedRoot) else {
            throw ReplayError.unsafePath(path.path)
        }
        try rejectLinks(lexical)
        let resolved = lexical.resolvingSymlinksInPath()
        guard inside(resolved, allowedRoot.resolvingSymlinksInPath()),
              !inside(resolved, originalRoot), resolved != originalRoot else {
            throw ReplayError.unsafePath(path.path)
        }
        if let attributes = try? fm.attributesOfItem(atPath: lexical.path) {
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  ((attributes[.referenceCount] as? NSNumber)?.intValue ?? 1) == 1 else {
                throw ReplayError.unsafePath(path.path)
            }
        }
        return lexical
    }

    public func noteURL(_ filename: String) throws -> URL {
        let components = filename.components(separatedBy: "/")
        guard !filename.hasPrefix("/"), filename.hasSuffix(".md"),
              components.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") && $0 != ".." }) else {
            throw ReplayError.unsafePath(filename)
        }
        return try validated(courseRoot.appendingPathComponent(filename), under: courseRoot)
    }

    /// Library assets use the same containment and link checks as editable notes.
    public func fileURL(_ filename: String) throws -> URL {
        let components = filename.components(separatedBy: "/")
        guard !filename.hasPrefix("/"), components.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") }) else {
            throw ReplayError.unsafePath(filename)
        }
        return try validated(courseRoot.appendingPathComponent(filename), under: courseRoot)
    }

    public func fileNames() throws -> [String] {
        try rejectLinks(courseRoot)
        guard let iterator = fm.enumerator(at: courseRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        var names: [String] = []
        for case let url as URL in iterator {
            try rejectLinks(url)
            if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true { continue }
            let name = String(url.path.dropFirst(courseRoot.path.count + 1))
            _ = try fileURL(name); names.append(name)
        }
        return names.sorted()
    }

    public func readFile(_ filename: String) throws -> Data { try Data(contentsOf: fileURL(filename)) }
    public func createAsset(_ filename: String, data: Data) throws {
        guard !filename.hasSuffix(".md") else { throw ReplayError.unsafePath(filename) }
        let url = try fileURL(filename)
        if filename.contains("/") { try createFolder(filename.components(separatedBy: "/").dropLast().joined(separator: "/")) }
        _ = try fileURL(filename)
        try data.write(to: url, options: .withoutOverwriting)
    }
    /// Permanent removal uses validated bytes without creating a recoverable note transaction.
    public func permanentlyRemoveFile(_ filename: String, expected: Data) throws {
        let url = try fileURL(filename)
        guard try readFile(filename) == expected else { throw ReplayError.conflict }
        try fm.removeItem(at: url)
    }

    public func removeAsset(_ filename: String, expected: Data) throws {
        guard !filename.hasSuffix(".md"), try readFile(filename) == expected else { throw ReplayError.conflict }
        try fm.removeItem(at: fileURL(filename))
    }

    /// Includes all files; deletion must archive every byte before removing a folder.
    public func libraryFolderTree(_ relative: String) throws -> [String] {
        let directory = try fileURL(relative + "/placeholder").deletingLastPathComponent()
        guard fm.fileExists(atPath: directory.path), let iterator = fm.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) else { throw ReplayError.unsafePath(relative) }
        var folders = [relative]
        for case let url as URL in iterator {
            try rejectLinks(url)
            let name = String(url.path.dropFirst(courseRoot.path.count + 1))
            if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                _ = try fileURL(name + "/placeholder"); folders.append(name)
            } else { _ = try fileURL(name) }
        }
        return folders
    }

    public func noteNames() throws -> [String] {
        try rejectLinks(courseRoot)
        guard let iterator = fm.enumerator(at: courseRoot, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return [] }
        var names: [String] = []
        for case let url as URL in iterator {
            try rejectLinks(url)
            if url.pathExtension == "md" {
                let relative = String(url.path.dropFirst(courseRoot.path.count + 1))
                _ = try noteURL(relative)
                names.append(relative)
            }
        }
        return names.sorted()
    }

    public func createFolder(_ relative: String) throws {
        let components = relative.components(separatedBy: "/")
        guard !relative.hasPrefix("/"), components.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") }) else {
            throw ReplayError.unsafePath(relative)
        }
        let url = courseRoot.appendingPathComponent(relative)
        try rejectLinks(url)
        guard inside(url.standardizedFileURL, courseRoot) else { throw ReplayError.unsafePath(relative) }
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        try rejectLinks(url)
    }

    /// Validate a folder before deletion. Never discard non-Markdown assets or links.
    public func markdownFolderTree(_ relative: String) throws -> [String] {
        let probe = try noteURL(relative + "/placeholder.md")
        let directory = probe.deletingLastPathComponent()
        guard fm.fileExists(atPath: directory.path), let iterator = fm.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) else { throw ReplayError.unsafePath(relative) }
        var folders = [relative]
        for case let url as URL in iterator {
            try rejectLinks(url)
            let name = String(url.path.dropFirst(courseRoot.path.count + 1))
            if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true { folders.append(name) }
            else { guard url.pathExtension == "md" else { throw ReplayError.invalidResponse("La carpeta contiene archivos que no son Markdown; muévelos antes de eliminarla.") }; _ = try noteURL(name) }
        }
        return folders
    }
    public func removeEmptyFolder(_ relative: String) throws {
        let directory = try noteURL(relative + "/placeholder.md").deletingLastPathComponent()
        guard try fm.contentsOfDirectory(atPath: directory.path).isEmpty else { throw ReplayError.conflict }
        try fm.removeItem(at: directory)
    }

    public func createNote(_ relative: String, text: String) throws {
        if try noteMutation?(relative, nil, text) == true { return }
        let url = try noteURL(relative)
        guard !fm.fileExists(atPath: url.path) else { throw ReplayError.invalidResponse("Ya existe una nota con ese nombre.") }
        if relative.contains("/") {
            let folder = relative.components(separatedBy: "/").dropLast().joined(separator: "/")
            try createFolder(folder)
        }
        _ = try noteURL(relative)
        // Exclusive creation refuses an existing file. Foundation does not allow
        // combining withoutOverwriting and atomic; replacements use writeNote.
        try Data(text.utf8).write(to: url, options: .withoutOverwriting)
    }

    public func renameFile(_ source: String, to destination: String) throws {
        guard source.components(separatedBy: "/").dropLast() == destination.components(separatedBy: "/").dropLast() else { throw ReplayError.unsafePath(destination) }
        let from = try fileURL(source), to = try fileURL(destination)
        guard try from.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
              !fm.fileExists(atPath: to.path) else { throw ReplayError.conflict }
        try fm.moveItem(at: from, to: to)
    }

    public func renameFolder(_ source: String, to destination: String) throws {
        guard !source.isEmpty, !destination.isEmpty,
              source.components(separatedBy: "/").dropLast() == destination.components(separatedBy: "/").dropLast() else { throw ReplayError.unsafePath(destination) }
        _ = try libraryFolderTree(source)
        let from = try fileURL(source + "/placeholder").deletingLastPathComponent()
        let to = try fileURL(destination + "/placeholder").deletingLastPathComponent()
        guard !fm.fileExists(atPath: to.path) else { throw ReplayError.conflict }
        try fm.moveItem(at: from, to: to)
    }

    public func folderNames() throws -> [String] {
        try rejectLinks(courseRoot)
        guard let iterator = fm.enumerator(at: courseRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        var result: [String] = []
        for case let url as URL in iterator {
            try rejectLinks(url)
            if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                result.append(String(url.path.dropFirst(courseRoot.path.count + 1)))
            }
        }
        return result.sorted()
    }

    public func readNote(_ filename: String) throws -> String {
        try String(contentsOf: noteURL(filename), encoding: .utf8)
    }

    public func writeNote(_ filename: String, expected: String, replacement: String) throws {
        if try noteMutation?(filename, expected, replacement) == true { return }
        let url = try noteURL(filename)
        guard try String(contentsOf: url, encoding: .utf8) == expected else { throw ReplayError.conflict }
        // Check again immediately before an atomic replacement; no user-supplied
        // path, symlink or hard link is accepted.
        _ = try noteURL(filename)
        try Data(replacement.utf8).write(to: url, options: .atomic)
    }

    public func removeNote(_ filename: String, expected: String) throws {
        if try noteMutation?(filename, expected, nil) == true { return }
        let url = try noteURL(filename)
        guard try readNote(filename) == expected else { throw ReplayError.conflict }
        try fm.removeItem(at: url)
    }

    public func writeStorage(_ relative: String, data: Data) throws {
        let url = storageRoot.appendingPathComponent(relative)
        _ = try validated(url, under: storageRoot)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try validated(url, under: storageRoot)
        try data.write(to: url, options: .atomic)
    }

    public func readStorage(_ relative: String) throws -> Data {
        try Data(contentsOf: validated(storageRoot.appendingPathComponent(relative), under: storageRoot))
    }

    public func removeStorage(_ relative: String) throws {
        let url = try validated(storageRoot.appendingPathComponent(relative), under: storageRoot)
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
    }

    public func removeStorageTree(_ relative: String) throws {
        guard !relative.hasPrefix("/"), relative.components(separatedBy: "/").allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") }) else {
            throw ReplayError.unsafePath(relative)
        }
        let directory = try validated(storageRoot.appendingPathComponent(relative + "/placeholder"), under: storageRoot).deletingLastPathComponent()
        guard fm.fileExists(atPath: directory.path) else { return }
        try rejectLinks(directory)
        guard let iterator = fm.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) else { throw ReplayError.unsafePath(relative) }
        for case let child as URL in iterator {
            try rejectLinks(child)
            if try child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory != true {
                _ = try validated(child, under: storageRoot)
            }
        }
        try fm.removeItem(at: directory)
    }

    public func loadSessions() throws -> [SessionDocument] {
        let directory = storageRoot.appendingPathComponent("sessions")
        guard fm.fileExists(atPath: directory.path) else { return [] }
        try rejectLinks(directory)
        return try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map {
                let url = try validated($0, under: storageRoot)
                return try JSONDecoder().decode(SessionDocument.self, from: Data(contentsOf: url))
            }.sorted { $0.metadata.startedAt > $1.metadata.startedAt }
    }

    public func save(_ session: SessionDocument) throws {
        guard UUID(uuidString: session.id) != nil else { throw ReplayError.unsafePath(session.id) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writeStorage("sessions/\(session.id).json", data: encoder.encode(session))
    }
}
