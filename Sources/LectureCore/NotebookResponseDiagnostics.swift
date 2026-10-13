import Foundation
import CryptoKit

public struct NotebookResponseValidationError: LocalizedError, Equatable, Sendable {
    public let code: String
    public let actual: Int?
    public let limit: Int?
    public let fields: String

    public var errorDescription: String? { message(language: "en") }

    public func message(language: String) -> String {
        if let actual, let limit {
            return language == "en"
                ? "Assistant response rejected: \(fields) is \(actual); maximum allowed is \(limit)."
                : "Respuesta del asistente rechazada: \(fields) es \(actual); el máximo permitido es \(limit)."
        }
        return language == "en"
            ? "Assistant response rejected: \(fields) cannot be combined in one response."
            : "Respuesta del asistente rechazada: \(fields) no se pueden combinar en una respuesta."
    }
}

public struct NotebookResponseDiagnostic: Codable, Sendable {
    public let id: String
    public let date: Date
    public let provider: NotesAIProvider
    public let notebookID: String
    public let requestID: String
    public let attempt: Int
    public let code: String
    public let responseBytes: Int
    public let responseSHA256: String
    public let edits: Int?
    public let readFiles: Int?
    public let outputs: Int?
    public let webActions: Int?
    public let actual: Int?
    public let limit: Int?
    public let decodingPath: String?

    init(text: String, error: Error, provider: NotesAIProvider, notebookID: String, requestID: String, attempt: Int) {
        id = UUID().uuidString; date = Date()
        self.provider = provider; self.notebookID = notebookID; self.requestID = requestID; self.attempt = attempt
        responseBytes = text.utf8.count
        responseSHA256 = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        let validation = error as? NotebookResponseValidationError
        code = validation?.code ?? "invalid_json"
        actual = validation?.actual; limit = validation?.limit
        let decoded = try? NotebookAssistantProtocol.decodeJSON(text)
        edits = decoded?.edits.count; readFiles = decoded?.readFiles.count
        outputs = decoded.map { $0.outputs?.count ?? 0 }; webActions = decoded.map { $0.webActions?.count ?? 0 }
        var context: DecodingError.Context?
        var missingKey: CodingKey?
        switch error {
        case DecodingError.keyNotFound(let key, let detail): context = detail; missingKey = key
        case DecodingError.typeMismatch(_, let detail), DecodingError.valueNotFound(_, let detail), DecodingError.dataCorrupted(let detail): context = detail
        default: break
        }
        decodingPath = context.map { detail in
            let keys = detail.codingPath + (missingKey.map { [$0] } ?? [])
            return String((keys.isEmpty ? "$" : keys.map(\.stringValue).joined(separator: ".")).prefix(200))
        }
    }
}

public struct NotebookResponseDiagnostics {
    public static let path = "diagnostics/notebook-responses.json"
    public static let maximumRecords = 100
    public static let maximumBytes = 131_072
    private static let lock = NSLock()
    let workspace: SafeWorkspace

    public init(workspace: SafeWorkspace) { self.workspace = workspace }
    public init(store: LocalMediaStore) throws { workspace = try SafeWorkspace(root: store.root, originalRoot: store.originalRoot) }

    public func append(_ record: NotebookResponseDiagnostic) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let file = try workspace.validated(workspace.storageRoot.appendingPathComponent(Self.path), under: workspace.storageRoot)
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        _ = try workspace.validated(file, under: workspace.storageRoot)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        var records: [NotebookResponseDiagnostic] = []
        if FileManager.default.fileExists(atPath: file.path) {
            let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber
            if (size?.intValue ?? Int.max) <= Self.maximumBytes {
                records = (try? decoder.decode([NotebookResponseDiagnostic].self, from: workspace.readStorage(Self.path))) ?? []
            }
        }
        records = Array(records.suffix(Self.maximumRecords - 1)) + [record]
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .secondsSince1970; encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(records)
        while data.count > Self.maximumBytes, records.count > 1 {
            records.removeFirst(); data = try encoder.encode(records)
        }
        guard data.count <= Self.maximumBytes else { throw MediaError.invalid("Diagnostic record exceeds the local storage limit.") }
        try workspace.writeStorage(Self.path, data: data)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
