import Foundation
import CryptoKit

public struct NotebookProfile: Codable, Equatable, Sendable {
    public var purpose = ""
    public var instructions = ""
    public var formatting = ""
    public var sourceRules = ""
    public init() {}
}

public struct NotebookActivity: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID().uuidString
    public var title: String
    public var date = Date()
    public init(_ title: String) { self.title = title }
}

public struct NotebookMessage: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID().uuidString
    public var role: String
    public var text: String
    public var date = Date()
    public var files: [String] = []
    public var checkpointID: String?
    public var activities: [NotebookActivity]?
    public var attachments: [NotebookAttachment]?
    public init(role: String, text: String, files: [String] = [], checkpointID: String? = nil, activities: [NotebookActivity]? = nil) {
        self.role = role; self.text = text; self.files = files; self.checkpointID = checkpointID; self.activities = activities
    }
}

public struct NotebookChat: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID().uuidString
    public var title: String
    public var messages: [NotebookMessage] = []
    public var draft = ""
    public var attachments: [NotebookAttachment]?
    public init(title: String = "Nuevo chat") { self.title = title }
}

public struct NotebookProjectState: Codable, Equatable, Sendable {
    public var profile: NotebookProfile
    public var chats: [NotebookChat] = []
    public var activeChatID: String?
    public var pendingDrafts: [NotebookChat]?
    public init() { profile = NotebookProfile() }
}

public struct NotebookCheckpoint: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID().uuidString
    public var notebookID: String
    public var date = Date()
    public var summary: String
    public var files: [String: String]
    public var changedFiles: [String]
    public var invalidatesProposals: Bool? = nil
}

public struct NotebookFileChange: Codable, Equatable, Sendable {
    public var path: String
    /// nil represents creation/deletion. Deletion is reserved for checkpoint restoration.
    public var before: String?
    public var after: String?
    public init(path: String, before: String?, after: String?) { self.path = path; self.before = before; self.after = after }
}

struct NotebookTransaction: Codable {
    var checkpoint: NotebookCheckpoint
    var changes: [NotebookFileChange]
}

/// All callers serialize writes on the app's main actor. The journal is durable before any note changes.
public final class NotebookProjectStore {
    public let workspace: SafeWorkspace
    public var notebooks: [Notebook]
    public private(set) var checkpoints: [NotebookCheckpoint] = []
    private var applying = false
    public var didChange: (() -> Void)?
    private let index = "projects/checkpoints.json"
    private let journal = "projects/transaction.json"

    public init(workspace: SafeWorkspace, notebooks: [Notebook]) throws {
        self.workspace = workspace; self.notebooks = notebooks
        if exists(index) { checkpoints = try JSONDecoder().decode([NotebookCheckpoint].self, from: workspace.readStorage(index)) }
        try recover()
    }
    private func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: workspace.storageRoot.appendingPathComponent(name).path) }
    public static func digest(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    private func statePath(_ id: String) -> String { "projects/" + Self.digest(id) + "/state.json" }
    public func loadState(_ notebook: Notebook) throws -> NotebookProjectState {
        let path = statePath(notebook.id)
        return exists(path) ? try JSONDecoder().decode(NotebookProjectState.self, from: workspace.readStorage(path)) : .init()
    }
    public func saveState(_ state: NotebookProjectState, notebookID: String) throws {
        try workspace.writeStorage(statePath(notebookID), data: JSONEncoder().encode(state))
    }
    public func owner(of path: String) -> Notebook? {
        notebooks.filter { $0.rootPrefix.isEmpty || path.hasPrefix($0.rootPrefix + "/") }
            .max { $0.rootPrefix.count < $1.rootPrefix.count }
    }
    public func validate(_ path: String, notebookID: String) throws {
        _ = try workspace.noteURL(path)
        guard owner(of: path)?.id == notebookID, owner(of: path)?.archivedAt == nil else { throw MediaError.invalid("El archivo no pertenece a este cuaderno: \(path)") }
    }
    public func texts(_ notebookID: String) throws -> [String: String] {
        var result: [String: String] = [:]
        for path in try workspace.noteNames() where owner(of: path)?.id == notebookID { result[path] = try workspace.readNote(path) }
        return result
    }
    private func blob(_ text: String) throws -> String {
        let hash = Self.digest(text), path = "projects/blobs/" + Self.digest(text) + ".txt"
        if !exists(path) { try workspace.writeStorage(path, data: Data(text.utf8)) }
        return hash
    }
    public func content(_ hash: String) throws -> String {
        guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else { throw MediaError.invalid("Versión dañada.") }
        let text = String(decoding: try workspace.readStorage("projects/blobs/" + hash + ".txt"), as: UTF8.self)
        guard Self.digest(text) == hash else { throw MediaError.invalid("Versión dañada.") }
        return text
    }
    private func manifest(_ texts: [String: String]) throws -> [String: String] { try texts.mapValues { try blob($0) } }
    private func persistIndex() throws { try workspace.writeStorage(index, data: JSONEncoder().encode(checkpoints)) }
    public func timeline(_ id: String) -> [NotebookCheckpoint] { checkpoints.filter { $0.notebookID == id } }
    @discardableResult public func capture(_ id: String, summary: String) throws -> NotebookCheckpoint {
        let files = try manifest(texts(id)), previous = timeline(id).last
        if let previous, previous.files == files { return previous }
        let changed = Set(files.keys).union(previous?.files.keys.map { $0 } ?? []).filter { files[$0] != previous?.files[$0] }.sorted()
        let checkpoint = NotebookCheckpoint(notebookID: id, summary: summary, files: files, changedFiles: changed)
        checkpoints.append(checkpoint)
        do { try persistIndex() } catch { checkpoints.removeLast(); throw error }
        didChange?(); return checkpoint
    }
    public func installWriteTracking() {
        workspace.noteMutation = { [weak self] path, before, after in
            guard let self, !self.applying else { return false }
            guard let notebook = self.owner(of: path) else { throw MediaError.invalid("Archivo sin cuaderno.") }
            _ = try self.apply(notebook.id, summary: before == nil ? "Crear \(URL(fileURLWithPath: path).lastPathComponent)" : "Guardar \(URL(fileURLWithPath: path).lastPathComponent)", changes: [.init(path: path, before: before, after: after)])
            return true
        }
    }
    @discardableResult public func apply(_ id: String, summary: String, changes: [NotebookFileChange], invalidatesProposals: Bool = false) throws -> NotebookCheckpoint {
        try recover()
        guard !applying, !changes.isEmpty, Set(changes.map { $0.path.precomposedStringWithCanonicalMapping.lowercased() }).count == changes.count else { throw MediaError.invalid("Cambios duplicados o vacíos.") }
        let before = try texts(id)
        for change in changes {
            try validate(change.path, notebookID: id)
            guard before[change.path] == change.before else { throw ReplayError.conflict }
            if change.before == nil, FileManager.default.fileExists(atPath: try workspace.noteURL(change.path).path) { throw ReplayError.conflict }
        }
        _ = try capture(id, summary: timeline(id).isEmpty ? "Inicio" : "Cambios anteriores")
        var after = before
        for change in changes { after[change.path] = change.after }
        let checkpoint = NotebookCheckpoint(notebookID: id, summary: summary, files: try manifest(after), changedFiles: changes.map(\.path).sorted(), invalidatesProposals: invalidatesProposals)
        let transaction = NotebookTransaction(checkpoint: checkpoint, changes: changes)
        try workspace.writeStorage(journal, data: JSONEncoder().encode(transaction))
        applying = true
        defer { applying = false }
        do {
            for change in changes { try write(change.path, from: change.before, to: change.after) }
            checkpoints.append(checkpoint)
            do { try persistIndex() } catch { checkpoints.removeLast(); throw error }
        } catch {
            // Recovery verifies each file before rollback, never overwriting an unrelated external edit.
            do { try recover() } catch { throw MediaError.invalid("La transacción necesita recuperación: \(error.localizedDescription)") }
            throw error
        }
        // A saved index is the commit point. A leftover journal is completed during recovery.
        try? workspace.writeStorage(journal, data: Data("null".utf8))
        didChange?(); return checkpoint
    }
    private func write(_ path: String, from: String?, to: String?) throws {
        if let to {
            if let from { try workspace.writeNote(path, expected: from, replacement: to) }
            else { try workspace.createNote(path, text: to) }
        } else if let from { try workspace.removeNote(path, expected: from) }
    }
    public func recover() throws {
        guard exists(journal), let transaction = try JSONDecoder().decode(NotebookTransaction?.self, from: workspace.readStorage(journal)) else { return }
        let committed = checkpoints.contains { $0.id == transaction.checkpoint.id }
        let wasApplying = applying; applying = true; defer { applying = wasApplying }
        for change in transaction.changes {
            try validate(change.path, notebookID: transaction.checkpoint.notebookID)
            let url = try workspace.noteURL(change.path)
            let current = FileManager.default.fileExists(atPath: url.path) ? try workspace.readNote(change.path) : nil
            guard current == change.before || current == change.after else { throw ReplayError.conflict }
        }
        for change in transaction.changes.reversed() {
            let url = try workspace.noteURL(change.path)
            let current = FileManager.default.fileExists(atPath: url.path) ? try workspace.readNote(change.path) : nil
            let desired = committed ? change.after : change.before
            if current != desired { try write(change.path, from: current, to: desired) }
        }
        try workspace.writeStorage(journal, data: Data("null".utf8))
    }
    @discardableResult public func restore(_ checkpoint: NotebookCheckpoint) throws -> NotebookCheckpoint {
        guard checkpoints.contains(checkpoint) else { throw MediaError.invalid("Versión desconocida.") }
        let current = try texts(checkpoint.notebookID)
        let target = try checkpoint.files.mapValues { try content($0) }
        let changes = Set(current.keys).union(target.keys).sorted().compactMap { path -> NotebookFileChange? in
            current[path] == target[path] ? nil : .init(path: path, before: current[path], after: target[path])
        }
        guard !changes.isEmpty else { return try capture(checkpoint.notebookID, summary: "Sin cambios") }
        return try apply(checkpoint.notebookID, summary: "Restaurar · \(checkpoint.summary)", changes: changes, invalidatesProposals: true)
    }
}
