import Foundation

public final class ReplayEngine {
    public private(set) var session: SessionDocument
    public let workspace: SafeWorkspace
    public var maxBatchSeconds: Double = 45
    public var maxBatchWords: Int = 120

    public init(session: SessionDocument, workspace: SafeWorkspace) {
        self.session = session; self.workspace = workspace
    }

    @discardableResult
    public func ingest(_ event: TranscriptEvent) throws -> Bool {
        guard Self.safeID(event.id), event.revision > 0, event.start >= 0, event.end >= event.start,
              event.end <= session.recording.duration else { throw ReplayError.invalidResponse("Segmento o tiempo inválido.") }
        if (session.eventVersions[event.id] ?? 0) >= event.revision { return false }
        // In-buffer ASR revisions replace the unstable version. A revision of
        // an already committed segment goes to review unless it is a known fixture.
        session.eventVersions[event.id] = event.revision
        if let i = session.transcript.firstIndex(where: { $0.id == event.id }) { session.transcript[i] = event }
        else { session.transcript.append(event) }
        if let i = session.buffer.firstIndex(where: { $0.id == event.id }) { session.buffer[i] = event }
        else { session.buffer.append(event) }
        try workspace.save(session)
        return true
    }

    public var readyToBatch: Bool {
        guard let first = session.buffer.first, let last = session.buffer.last else { return false }
        return last.end - first.start >= maxBatchSeconds ||
            session.buffer.reduce(0) { $0 + $1.text.split(whereSeparator: { $0.isWhitespace }).count } >= maxBatchWords
    }

    public func replayNext(deferApplication: Bool = false) throws {
        guard session.replayCursor < SyntheticFixtures.steps.count else { return }
        let step = SyntheticFixtures.steps[session.replayCursor]
        let accepted = try ingest(step.event)
        if accepted && !deferApplication && (step.topicBoundary || readyToBatch) { try flush() }
        session.replayCursor += 1
        try workspace.save(session)
    }

    public func flush() throws {
        try process(responses: SyntheticFixtures.mockResponse(for: session.buffer))
    }

    public func process(responses: [MockDecision]) throws {
        let events = session.buffer
        guard !events.isEmpty else { return }
        let batchID = digest(Data(events.map { "\($0.id):\($0.revision)" }.joined(separator: "|").utf8))
        guard !session.appliedBatchIDs.contains(batchID) else {
            session.buffer.removeAll(); try workspace.save(session); return
        }
        guard responses.count == events.count,
              Set(responses.map(\.eventID)) == Set(events.map(\.id)) else {
            throw ReplayError.invalidResponse("La respuesta debe cubrir exactamente los segmentos del lote.")
        }
        let before = try workspace.readNote(session.targetNote)
        try checkHash(before)
        var after = before
        var next = session
        let segmentsBefore = next.segments
        for event in events {
            let decision = responses.first { $0.eventID == event.id }!
            next.decisions.append("\(timestamp(event.start)) · \(decision.kind.rawValue) · \(decision.reason)")
            switch decision.kind {
            case .append:
                guard !decision.text.isEmpty else { throw ReplayError.invalidResponse("Contenido vacío.") }
                if next.segments.contains(where: { $0.id == event.id }) {
                    addReview(event, reason: "Revisión de un segmento ya publicado; confirmar el reemplazo.", text: decision.text, into: &next)
                } else {
                    ensureHeading(in: &after)
                    after += "\n" + block(event.id, decision.text) + "\n"
                    next.segments.append(CommittedSegment(id: event.id, text: decision.text, lowPriority: false, excluded: false))
                }
            case .correction, .retraction, .omit:
                guard let target = decision.targetID,
                      let i = next.segments.firstIndex(where: { $0.id == target && !$0.excluded }) else {
                    addReview(event, reason: "No se encontró un referente activo inequívoco.", text: decision.text, into: &next)
                    continue
                }
                let oldBlock = block(target, next.segments[i].text)
                guard after.components(separatedBy: oldBlock).count == 2 else { throw ReplayError.conflict }
                if decision.kind == .correction {
                    guard !decision.text.isEmpty else { throw ReplayError.invalidResponse("Corrección vacía.") }
                    after = after.replacingOccurrences(of: oldBlock, with: block(target, decision.text))
                    next.segments[i].text = decision.text
                } else {
                    after = after.replacingOccurrences(of: oldBlock, with: "")
                    next.segments[i].excluded = true
                }
            case .lowerPriority:
                if let target = decision.targetID, let i = next.segments.firstIndex(where: { $0.id == target }) {
                    next.segments[i].lowPriority = true
                } else { addReview(event, reason: "Prioridad con referente ambiguo.", text: decision.text, into: &next) }
            case .aside:
                break
            case .review:
                addReview(event, reason: decision.reason, text: decision.text, into: &next)
            }
        }
        next.buffer.removeAll()
        next.appliedBatchIDs.append(batchID)
        try commit(before: before, after: after, next: &next, segmentsBefore: segmentsBefore,
                   reason: "Lote simulado de \(events.count) segmentos")
    }

    public func resolveReview(_ id: String, replacement: String?) throws {
        guard let i = session.reviews.firstIndex(where: { $0.id == id && !$0.resolved }) else { return }
        let before = try workspace.readNote(session.targetNote)
        try checkHash(before)
        var next = session
        let segmentsBefore = next.segments
        var after = before
        if let replacement {
            let text = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw ReplayError.invalidResponse("Escribe el texto confirmado antes de añadirlo.") }
            let eventID = next.reviews[i].eventID
            if let segmentIndex = next.segments.firstIndex(where: { $0.id == eventID && !$0.excluded }) {
                let old = block(eventID, next.segments[segmentIndex].text)
                guard after.components(separatedBy: old).count == 2 else { throw ReplayError.conflict }
                after = after.replacingOccurrences(of: old, with: block(eventID, text))
                next.segments[segmentIndex].text = text
            } else {
                ensureHeading(in: &after)
                let segmentID = "review-\(next.reviews[i].id)"
                after += "\n" + block(segmentID, text) + "\n"
                next.segments.append(CommittedSegment(id: segmentID, text: text, lowPriority: false, excluded: false))
            }
        }
        next.reviews[i].resolved = true
        try commit(before: before, after: after, next: &next, segmentsBefore: segmentsBefore, reason: "Revisión humana")
    }

    public func undo() throws {
        guard let index = session.history.lastIndex(where: { !$0.undone }) else { throw ReplayError.noUndo }
        let change = session.history[index]
        // Use the filename recorded with the edit, not a later UI selection.
        try workspace.writeNote(change.filename, expected: change.after, replacement: change.before)
        var next = session
        next.history[index].undone = true
        next.segments = change.segmentsBefore
        // Undo only review resolutions attached to this edit. Reviews created
        // by later transcript-only batches must remain pending and recoverable.
        for previous in change.reviewsBefore {
            if let changed = change.reviewsAfter.first(where: { $0.id == previous.id }), changed != previous,
               let i = next.reviews.firstIndex(where: { $0.id == previous.id && $0 == changed }) {
                next.reviews[i] = previous
            }
        }
        next.lastExpectedNoteHash = digest(Data(change.before.utf8))
        try persistOrRollback(next, filename: change.filename, current: change.before, rollback: change.after)
        session = next
    }

    public func updateMetadata(subject: String, units: String, exams: String, mode: InputMode,
                               topicTags: [(units: String, exams: String)]? = nil) throws {
        var next = session
        let cleanedSubject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        next.metadata.subject = cleanedSubject.isEmpty ? "Derecho del Trabajo" : cleanedSubject
        next.metadata.unitTags = SessionMetadata.tags(from: units)
        next.metadata.examTags = SessionMetadata.tags(from: exams)
        next.metadata.inputMode = mode
        if let topicTags {
            guard topicTags.count == next.topics.count else { throw ReplayError.invalidResponse("Etiquetas de sección incompletas.") }
            for i in next.topics.indices {
                next.topics[i].unitTags = SessionMetadata.tags(from: topicTags[i].units)
                next.topics[i].examTags = SessionMetadata.tags(from: topicTags[i].exams)
            }
        }
        try workspace.save(next)
        session = next
    }

    public func selectNote(_ name: String) throws {
        guard session.transcript.isEmpty && session.history.isEmpty else {
            throw ReplayError.invalidResponse("Cambia de nota creando una sesión nueva, para conservar la trazabilidad.")
        }
        let note = try workspace.readNote(name)
        var next = session
        next.targetNote = name
        next.lastExpectedNoteHash = digest(Data(note.utf8))
        try workspace.save(next); session = next
    }

    public func acknowledgeEditorSave(filename: String, before: String, after: String) throws {
        guard filename == session.targetNote else { return }
        try checkHash(before)
        guard try workspace.readNote(filename) == after else { throw ReplayError.conflict }
        var next = session
        next.lastExpectedNoteHash = digest(Data(after.utf8))
        for i in next.segments.indices where !next.segments[i].excluded {
            let id = next.segments[i].id
            let opening = "<!-- replay-segment:\(session.id):\(id) -->\n"
            let closing = "\n<!-- /replay-segment:\(session.id):\(id) -->"
            if let a = after.range(of: opening), let b = after.range(of: closing, range: a.upperBound..<after.endIndex) {
                next.segments[i].text = String(after[a.upperBound..<b.lowerBound])
            } else { next.segments[i].excluded = true }
        }
        try workspace.save(next)
        session = next
    }

    private func checkHash(_ text: String) throws {
        if let expected = session.lastExpectedNoteHash, digest(Data(text.utf8)) != expected { throw ReplayError.conflict }
    }

    private func commit(before: String, after: String, next: inout SessionDocument,
                        segmentsBefore: [CommittedSegment], reason: String) throws {
        if before != after {
            next.history.append(FileChange(id: UUID().uuidString, filename: session.targetNote, before: before, after: after,
                                           reason: reason, date: Date(), segmentsBefore: segmentsBefore,
                                           segmentsAfter: next.segments, reviewsBefore: session.reviews,
                                           reviewsAfter: next.reviews, undone: false))
            next.lastExpectedNoteHash = digest(Data(after.utf8))
            try workspace.writeNote(session.targetNote, expected: before, replacement: after)
            try persistOrRollback(next, filename: session.targetNote, current: after, rollback: before)
        } else { try workspace.save(next) }
        session = next
    }

    private func persistOrRollback(_ next: SessionDocument, filename: String, current: String, rollback: String) throws {
        do { try workspace.save(next) }
        catch {
            try workspace.writeNote(filename, expected: current, replacement: rollback)
            throw error
        }
    }

    private func addReview(_ event: TranscriptEvent, reason: String, text: String, into next: inout SessionDocument) {
        next.reviews.append(ReviewItem(id: UUID().uuidString, eventID: event.id, transcript: event.text,
                                      reason: reason, suggestedText: text, resolved: false))
    }

    private func ensureHeading(in note: inout String) {
        let marker = "<!-- synthetic-session:\(session.id) -->"
        if !note.contains(marker) {
            note += "\n\n\(marker)\n## Sesión sintética · \(session.metadata.localDate)\n\n"
            note += "> Prueba de texto con respuestas simuladas. Los ejemplos no son referencias legales.\n"
        }
    }

    private func block(_ id: String, _ text: String) -> String {
        "<!-- replay-segment:\(session.id):\(id) -->\n\(text)\n<!-- /replay-segment:\(session.id):\(id) -->"
    }

    private static func safeID(_ id: String) -> Bool {
        !id.isEmpty && id.count < 120 && id.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
        }
    }
}

public struct DiffLine: Identifiable, Equatable, Sendable {
    public var id: Int
    public var prefix: String
    public var text: String
}

public enum NoteDiff {
    // A bounded, readable single-hunk diff: common prefix/suffix are context;
    // the entire changed region is represented, never hidden by set comparisons.
    public static func lines(before: String, after: String) -> [DiffLine] {
        let old = before.components(separatedBy: "\n"), new = after.components(separatedBy: "\n")
        var prefix = 0
        while prefix < min(old.count, new.count) && old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(old.count, new.count) - prefix && old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
        guard prefix != old.count || prefix != new.count else { return [] }
        var result: [(String, String)] = []
        result += old[max(0, prefix - 2)..<prefix].map { (" ", $0) }
        result += old[prefix..<(old.count - suffix)].map { ("−", $0) }
        result += new[prefix..<(new.count - suffix)].map { ("+", $0) }
        result += new[(new.count - suffix)..<min(new.count, new.count - suffix + 2)].map { (" ", $0) }
        return result.enumerated().map { DiffLine(id: $0.offset, prefix: $0.element.0, text: $0.element.1) }
    }
}
