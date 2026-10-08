import Foundation
import CryptoKit

public enum AIStage: String, Codable, Sendable { case queued, checking, sending, ready, failed, interrupted, cancelled }
public enum AIAction: String, Codable, Sendable { case add, correct, retract, omit, aside, priority, uncertain }
public struct AIDecision: Codable, Identifiable, Sendable {
    public var id: String
    public var sourceIDs: [String]
    public var action: AIAction
    public var text: String
    public var reason: String
    public var targetQuote: String?
    public var resolution: String?
    public var editorChangeID: String?
}
public struct AIBatch: Codable, Identifiable, Sendable {
    public var id: String
    public var requestKey: String
    public var mediaID: String
    public var notebookID: String
    public var targetNote: String
    public var createdAt: Date
    public var stage: AIStage
    public var segments: [MediaTranscriptSegment]
    public var priorSegments: [MediaTranscriptSegment]
    public var context: String
    public var expectedNote: String
    public var mode: InputMode
    public var decisions: [AIDecision]
    public var error: String?
    public var attempts: Int
    public var reportedCost: Double?
    public var downstreamModel: String?
    public var syntheticDemoProvenance: String? = nil
    public var model: String = OpenRouterHarness.model
    public var providerConfiguration: AIProviderConfiguration? = nil
}
public struct AIApplyJournal: Codable, Sendable {
    public var proposalID: String
    public var batchID: String
    public var filename: String
    public var before: String
    public var after: String
    public var editorChangeID: String?
    public var state: String
}

/// The outbox stores exactly the selected transcript and a bounded relevant
/// excerpt. Full note snapshots stay local and only guard later approval.
public final class AIOutbox {
    public let workspace: SafeWorkspace
    public private(set) var batches: [AIBatch] = []
    public let maximumQueued = 20
    public init(workspace: SafeWorkspace) throws {
        self.workspace = workspace
        let directory = workspace.storageRoot.appendingPathComponent("ai-outbox")
        if FileManager.default.fileExists(atPath: directory.path) {
            for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where url.pathExtension == "json" {
                let data = try Data(contentsOf: workspace.validated(url, under: workspace.storageRoot))
                var batch = try JSONDecoder().decode(AIBatch.self, from: data)
                guard UUID(uuidString: batch.id) != nil else { throw MediaError.invalid("Lote de IA inválido.") }
                if let configuration = batch.providerConfiguration {
                    try configuration.validate()
                    guard batch.model == configuration.model else { throw MediaError.invalid("Modelo del lote incoherente con su proveedor.") }
                } else if batch.model != OpenRouterHarness.model { throw MediaError.invalid("Lote de IA antiguo con modelo inválido.") }
                _ = try workspace.noteURL(batch.targetNote)
                if [.sending, .checking].contains(batch.stage) { batch.stage = .interrupted; batch.error = "Petición interrumpida. Revisa o reintenta explícitamente; no se ha cambiado la nota." }
                batches.append(batch)
            }
            batches.sort { $0.createdAt < $1.createdAt }
            for batch in batches { try persist(batch) }
        }
    }
    public func replace(_ batch: AIBatch) throws {
        try persist(batch)
        if let index = batches.firstIndex(where: { $0.id == batch.id }) { batches[index] = batch }
    }
    private func persist(_ batch: AIBatch) throws {
        guard UUID(uuidString: batch.id) != nil else { throw MediaError.invalid("Lote de IA inválido.") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try workspace.writeStorage("ai-outbox/\(batch.id).json", data: encoder.encode(batch))
    }
    public static func digest(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    public static func relevantContext(note: String, selected: [MediaTranscriptSegment], maximum: Int = 2000) -> String {
        let ignored = Set(["clase", "copiar", "importante", "concepto", "anterior", "profesor", "ejemplo", "trabajo", "vamos", "hacer", "tiene", "puede", "derecho"])
        let terms = Set(selected.flatMap { $0.text.lowercased().split { !$0.isLetter }.map(String.init) }.filter { $0.count >= 5 && !ignored.contains($0) })
        let paragraphs = note.components(separatedBy: "\n\n")
        var ranked: [(Int, Int, String)] = []
        for (index, text) in paragraphs.enumerated() {
            let words: Set<String> = Set(text.lowercased().split { !$0.isLetter }.map(String.init))
            let score: Int = terms.intersection(words).count
            ranked.append((score, index, text))
        }
        ranked.sort { left, right in left.0 == right.0 ? left.1 < right.1 : left.0 > right.0 }
        var chosen: [(Int, String)] = []; var length = 0
        for (score, index, text) in ranked where score > 0 || (index == 0 && text.hasPrefix("#")) {
            guard length < maximum else { break }
            let part = String(text.prefix(maximum - length)); chosen.append((index, part)); length += part.count + 2
        }
        return chosen.sorted { $0.0 < $1.0 }.map(\.1).joined(separator: "\n\n")
    }
    public static func groups(_ segments: [MediaTranscriptSegment], flush: Bool) -> [[MediaTranscriptSegment]] {
        var result: [[MediaTranscriptSegment]] = []; var pending: [MediaTranscriptSegment] = []; var words = 0
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            pending.append(segment); words += segment.text.split(whereSeparator: \.isWhitespace).count
            if words >= 120 || segment.end - (pending.first?.start ?? segment.start) >= 45 || pending.count >= 20 { result.append(pending); pending = []; words = 0 }
        }
        if flush && !pending.isEmpty { result.append(pending) }
        return result
    }
    @discardableResult public func enqueue(media: MediaJob, selected: [MediaTranscriptSegment], prior: [MediaTranscriptSegment] = []) throws -> AIBatch {
        guard !selected.isEmpty, selected.count <= 32, Set(selected.map(\.id)).count == selected.count,
              selected.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start && $0.text.count <= 4000 }),
              selected.map(\.text).joined().count <= 12_000 else { throw MediaError.invalid("Selecciona un fragmento de transcripción más pequeño.") }
        let note = try workspace.readNote(media.targetNote)
        let context = Self.relevantContext(note: note, selected: selected)
        let previous = Array(prior.suffix(2))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(selected + previous)
        let key = Self.digest(media.id + media.targetNote + String(decoding: data, as: UTF8.self) + Self.digest(note) + context + OpenRouterHarness.model + "privacy-v1")
        if let existing = batches.first(where: { $0.requestKey == key }) { return existing }
        guard batches.filter({ [.queued, .checking, .sending].contains($0.stage) }).count < maximumQueued else { throw MediaError.invalid("La cola tiene 20 lotes. Se pausa el envío; los fragmentos siguen guardados en local.") }
        let batch = AIBatch(id: UUID().uuidString, requestKey: key, mediaID: media.id, notebookID: media.notebookID, targetNote: media.targetNote, createdAt: Date(), stage: .queued, segments: selected, priorSegments: previous, context: context, expectedNote: note, mode: media.inputMode ?? .lecture, decisions: [], error: nil, attempts: 0)
        try persist(batch); batches.append(batch); return batch
    }
    public func recoverApplications(editor: NotebookEditor) throws {
        let folder = workspace.storageRoot.appendingPathComponent("ai-apply")
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        for url in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) where url.pathExtension == "json" {
            var journal = try JSONDecoder().decode(AIApplyJournal.self, from: Data(contentsOf: workspace.validated(url, under: workspace.storageRoot)))
            guard let change = editor.history.last(where: { $0.filename == journal.filename && $0.before == journal.before && $0.after == journal.after }),
                  let i = batches.firstIndex(where: { $0.id == journal.batchID }), let j = batches[i].decisions.firstIndex(where: { $0.id == journal.proposalID }) else { continue }
            journal.editorChangeID = change.id; journal.state = change.undone ? "undone" : "applied"
            batches[i].decisions[j].editorChangeID = change.id
            if batches[i].decisions[j].resolution != "excluded" { batches[i].decisions[j].resolution = change.undone ? nil : "applied" }
            try saveJournal(journal); try persist(batches[i])
        }
    }
    private func saveJournal(_ journal: AIApplyJournal) throws {
        try workspace.writeStorage("ai-apply/\(journal.proposalID).json", data: JSONEncoder().encode(journal))
    }
    public static func candidate(batch: AIBatch, decision: AIDecision, text: String, quote: String?) throws -> String {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count <= 12_000 else { throw MediaError.invalid("Propuesta demasiado larga.") }
        switch decision.action {
        case .omit, .aside: throw MediaError.invalid("Esta decisión conserva el fragmento fuera de los apuntes.")
        case .correct, .retract:
            guard let quote, !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  batch.expectedNote.components(separatedBy: quote).count == 2 else { throw MediaError.invalid("La corrección necesita una cita exacta y única de la nota; revisa el destino.") }
            guard decision.action == .retract || !clean.isEmpty else { throw MediaError.invalid("Confirma el texto corregido.") }
            return batch.expectedNote.replacingOccurrences(of: quote, with: decision.action == .retract ? "" : clean)
        default:
            guard !clean.isEmpty else { throw MediaError.invalid("Confirma el texto de la propuesta.") }
            if batch.expectedNote.contains(clean) { throw MediaError.invalid("Este texto ya está en la nota. Puedes descartar la propuesta duplicada.") }
            return batch.expectedNote.trimmingCharacters(in: .newlines) + "\n\n" + clean + "\n"
        }
    }
    @discardableResult public func apply(batchID: String, proposalID: String, text: String, quote: String?, editor: NotebookEditor, hasDraft: Bool) throws -> EditorChange {
        try recoverApplications(editor: editor)
        guard !hasDraft, let i = batches.firstIndex(where: { $0.id == batchID }), let j = batches[i].decisions.firstIndex(where: { $0.id == proposalID }), batches[i].decisions[j].resolution == nil else { throw MediaError.invalid("Guarda el borrador o revisa el estado de esta propuesta antes de aplicar.") }
        let batch = batches[i]; let decision = batch.decisions[j]
        guard try workspace.readNote(batch.targetNote) == batch.expectedNote else { throw ReplayError.conflict }
        let after = try Self.candidate(batch: batch, decision: decision, text: text, quote: quote)
        var journal = AIApplyJournal(proposalID: decision.id, batchID: batch.id, filename: batch.targetNote, before: batch.expectedNote, after: after, state: "pending")
        try saveJournal(journal)
        let change = try editor.save(filename: batch.targetNote, expected: batch.expectedNote, replacement: after)
        journal.editorChangeID = change.id; journal.state = "applied"; try saveJournal(journal)
        batches[i].decisions[j].resolution = "applied"; batches[i].decisions[j].editorChangeID = change.id
        try acknowledgeAppEdit(filename: batch.targetNote, before: batch.expectedNote, after: after)
        try persist(batches[i]); return change
    }
    public func dismiss(batchID: String, proposalID: String) throws {
        guard let i = batches.firstIndex(where: { $0.id == batchID }), let j = batches[i].decisions.firstIndex(where: { $0.id == proposalID }), batches[i].decisions[j].resolution == nil else { return }
        batches[i].decisions[j].resolution = "excluded"; try persist(batches[i])
    }
    public func acknowledgeAppEdit(filename: String, before: String, after: String) throws {
        for i in batches.indices where batches[i].targetNote == filename && batches[i].expectedNote == before {
            batches[i].expectedNote = after; try persist(batches[i])
        }
    }
}
