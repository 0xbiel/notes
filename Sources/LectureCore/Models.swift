import Foundation
import CryptoKit

public enum InputMode: String, Codable, CaseIterable, Sendable {
    case lecture = "Clase"
    case dictation = "Dictado personal"
}

public struct SessionMetadata: Codable, Equatable, Sendable {
    public var startedAt: Date
    public var timezoneID: String
    public var localDate: String
    public var localTime: String
    public var subject: String
    public var unitTags: [String]
    public var examTags: [String]
    public var suggestedUnits: [String]
    public var suggestedExams: [String]
    public var inputMode: InputMode

    public init(date: Date = Date(), timezone: TimeZone = .current, mode: InputMode = .lecture) {
        startedAt = date
        timezoneID = timezone.identifier
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timezone
        formatter.dateFormat = "yyyy-MM-dd"
        localDate = formatter.string(from: date)
        formatter.dateFormat = "HH:mm:ss"
        localTime = formatter.string(from: date)
        subject = "Derecho del Trabajo"
        unitTags = []
        examTags = []
        suggestedUnits = ["Contratos formativos"]
        suggestedExams = ["Parcial 1"]
        inputMode = mode
    }

    public static func tags(from text: String) -> [String] {
        var seen = Set<String>()
        return text.split(separator: ",").compactMap {
            let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return !value.isEmpty && seen.insert(value.lowercased()).inserted ? value : nil
        }
    }
}

public struct RecordingReference: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var relativePath: String
    public var duration: Double
    public var synthetic: Bool
}

public struct TopicSection: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var recordingID: String
    public var start: Double
    public var end: Double
    public var unitTags: [String]
    public var examTags: [String]
    public var noteReference: String? = nil
}

public struct TranscriptEvent: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var revision: Int
    public var start: Double
    public var end: Double
    public var text: String

    public init(id: String, revision: Int = 1, start: Double, end: Double, text: String) {
        self.id = id; self.revision = revision; self.start = start; self.end = end; self.text = text
    }
}

public enum DecisionKind: String, Codable, Sendable {
    case append, correction, retraction, lowerPriority, omit, aside, review
}

public struct MockDecision: Codable, Equatable, Sendable {
    public var eventID: String
    public var kind: DecisionKind
    public var targetID: String?
    public var text: String
    public var reason: String

    public init(eventID: String, kind: DecisionKind, targetID: String? = nil, text: String = "", reason: String) {
        self.eventID = eventID; self.kind = kind; self.targetID = targetID; self.text = text; self.reason = reason
    }
}

public struct CommittedSegment: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var text: String
    public var lowPriority: Bool
    public var excluded: Bool
}

public struct ReviewItem: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var eventID: String
    public var transcript: String
    public var reason: String
    public var suggestedText: String
    public var resolved: Bool
}

public struct FileChange: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var filename: String
    public var before: String
    public var after: String
    public var reason: String
    public var date: Date
    public var segmentsBefore: [CommittedSegment]
    public var segmentsAfter: [CommittedSegment]
    public var reviewsBefore: [ReviewItem]
    public var reviewsAfter: [ReviewItem]
    public var undone: Bool
}

public struct SessionDocument: Codable, Identifiable, Sendable {
    public var schemaVersion = 1
    public var id: String
    public var metadata: SessionMetadata
    public var recording: RecordingReference
    public var topics: [TopicSection]
    public var targetNote: String
    public var transcript: [TranscriptEvent] = []
    public var buffer: [TranscriptEvent] = []
    public var eventVersions: [String: Int] = [:]
    public var appliedBatchIDs: [String] = []
    public var segments: [CommittedSegment] = []
    public var reviews: [ReviewItem] = []
    public var history: [FileChange] = []
    public var decisions: [String] = []
    public var replayCursor = 0
    public var notebookID = "derecho"
    public var lastExpectedNoteHash: String?

    public init(id: String, metadata: SessionMetadata, recording: RecordingReference, topics: [TopicSection], targetNote: String) {
        self.id = id; self.metadata = metadata; self.recording = recording; self.topics = topics; self.targetNote = targetNote
    }
}

public func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

public func timestamp(_ seconds: Double) -> String {
    let total = max(0, Int(seconds))
    return String(format: "%02d:%02d", total / 60, total % 60)
}

public enum ReplayError: LocalizedError {
    case unsafePath(String), conflict, invalidResponse(String), noUndo, missingWorkspace
    public var errorDescription: String? {
        switch self {
        case .unsafePath(let p): "Ruta rechazada por la protección de copia: \(p)"
        case .conflict: "La copia cambió fuera de esta sesión. No se sobrescribió; abre una sesión nueva o revisa el conflicto."
        case .invalidResponse(let text): "Respuesta simulada inválida: \(text)"
        case .noUndo: "No quedan cambios para deshacer."
        case .missingWorkspace: "No se encontró el workspace independiente del prototipo."
        }
    }
}
