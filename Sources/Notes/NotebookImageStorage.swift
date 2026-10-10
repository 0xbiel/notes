import Foundation
import CryptoKit
import LectureCore

/// Only generated images are managed; imported user files are never garbage-collected.
enum NotebookImageStorage {
    static func managed(_ path: String) -> Bool {
        if path.components(separatedBy: "/").contains(".palladium-images") { return true }
        guard path.components(separatedBy: "/").dropLast().last == "assets" else { return false }
        let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return (stem.hasPrefix("image-") && UUID(uuidString: String(stem.dropFirst(6))) != nil)
            || (stem.count == 64 && stem.allSatisfy { $0.isHexDigit })
    }
    static let pattern = try! NSRegularExpression(pattern: #"!\[[^\]\n]*\]\(([^\n)]+)\)"#)
    static func references(_ text: String, note: String, workspace: SafeWorkspace) -> [(range: NSRange, path: String)] {
        let source = text as NSString
        let directory = workspace.courseRoot.appendingPathComponent(note).deletingLastPathComponent()
        return pattern.matches(in: text, range: NSRange(location: 0, length: source.length)).compactMap { match in
            let range = match.range(at: 1), raw = source.substring(with: range)
            guard let decoded = raw.removingPercentEncoding, !decoded.hasPrefix("/"), !decoded.contains(":"), !decoded.contains("\n") else { return nil }
            let url = directory.appendingPathComponent(decoded).standardizedFileURL
            guard url.path.hasPrefix(workspace.courseRoot.path + "/") else { return nil }
            let path = String(url.path.dropFirst(workspace.courseRoot.path.count + 1))
            guard (try? workspace.fileURL(path)) != nil else { return nil }
            return (range, path)
        }
    }
    static func relative(_ path: String, from note: String) -> String {
        var target = path.components(separatedBy: "/"), parent = note.components(separatedBy: "/").dropLast().map { $0 }
        while target.first == parent.first, !target.isEmpty, !parent.isEmpty { target.removeFirst(); parent.removeFirst() }
        return (Array(repeating: "..", count: parent.count) + target).joined(separator: "/")
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "()#?"))) ?? path
    }
    static func recovery(_ path: String) -> String {
        "image-recovery/" + SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined() + ".bin"
    }
}

@MainActor extension Workbench {
    func synchronizeDocumentImages(previous: String, current: String, note: String) {
        guard let workspace else { return }
        do {
            let old = Set(NotebookImageStorage.references(previous, note: note, workspace: workspace).map(\.path).filter(NotebookImageStorage.managed))
            let new = Set(NotebookImageStorage.references(current, note: note, workspace: workspace).map(\.path).filter(NotebookImageStorage.managed))
            // Recover bytes before Markdown rendering when an undo/history restore brings an image back.
            for path in new where !FileManager.default.fileExists(atPath: try workspace.fileURL(path).path) {
                if let bytes = try? workspace.readStorage(NotebookImageStorage.recovery(path)) { try workspace.createAsset(path, data: bytes) }
            }
            guard !old.subtracting(new).isEmpty else { return }
            var referenced = Set<String>()
            for filename in try workspace.noteNames() {
                let text = try filename == note ? current : (drafts[filename] ?? workspace.readNote(filename))
                referenced.formUnion(NotebookImageStorage.references(text, note: filename, workspace: workspace).map(\.path))
            }
            for path in old.subtracting(new).subtracting(referenced) {
                guard let bytes = try? workspace.readFile(path) else { continue }
                // Recovery bytes are private history, outside the live image folder.
                try workspace.writeStorage(NotebookImageStorage.recovery(path), data: bytes)
                try workspace.removeAsset(path, expected: bytes)
            }
        } catch { errorText = error.localizedDescription }
    }
}

@MainActor extension Workbench {
    func migrateGeneratedImages(_ text: String, note: String) throws -> String {
        guard let workspace, let owner = projects?.owner(of: note) else { return text }
        var result = text as NSString
        for reference in NotebookImageStorage.references(text, note: note, workspace: workspace).reversed()
            where NotebookImageStorage.managed(reference.path) && !reference.path.components(separatedBy: "/").contains(".palladium-images") {
            let bytes = try workspace.readFile(reference.path)
            _ = try DocumentImageInput.validated(bytes)
            let target = (owner.rootPrefix.isEmpty ? "" : owner.rootPrefix + "/") + ".palladium-images/" + URL(fileURLWithPath: reference.path).lastPathComponent
            if FileManager.default.fileExists(atPath: try workspace.fileURL(target).path) {
                guard try workspace.readFile(target) == bytes else { throw ReplayError.conflict }
            } else { try workspace.createAsset(target, data: bytes) }
            result = result.replacingCharacters(in: reference.range, with: NotebookImageStorage.relative(target, from: note)) as NSString
        }
        return result as String
    }
}
