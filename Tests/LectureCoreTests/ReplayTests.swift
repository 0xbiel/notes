import XCTest
@testable import LectureCore

final class ReplayTests: XCTestCase {
    private func environment() throws -> (SafeWorkspace, URL) {
        let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = packageRoot.appendingPathComponent(".test-workspaces/DerechoReplayTests-\(UUID().uuidString)")
        let original = root.appendingPathComponent("original")
        let workspace = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("copied-course"), withIntermediateDirectories: true)
        let text = "# Tema de prueba\n\n> Relacionado: [[Otra nota]]\n\n## 1. Concepto\n\nTexto base intacto.\n"
        try text.write(to: original.appendingPathComponent("Tema.md"), atomically: true, encoding: .utf8)
        try text.write(to: workspace.appendingPathComponent("copied-course/Tema.md"), atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (try SafeWorkspace(root: workspace, originalRoot: original), original)
    }

    private func engine(_ workspace: SafeWorkspace) throws -> ReplayEngine {
        ReplayEngine(session: try SyntheticFixtures.newSession(workspace: workspace, note: "Tema.md"), workspace: workspace)
    }

    func testRejectsOriginalTraversalAbsoluteAndHiddenPaths() throws {
        let (workspace, original) = try environment()
        XCTAssertThrowsError(try workspace.validated(original.appendingPathComponent("Tema.md"), under: workspace.courseRoot))
        for name in ["../original/Tema.md", "/tmp/Tema.md", "a/../../Tema.md", ".hidden.md", "a/.hidden.md"] {
            XCTAssertThrowsError(try workspace.noteURL(name), name)
        }
        XCTAssertThrowsError(try workspace.writeStorage("../copied-course/Tema.md", data: Data()))
        XCTAssertThrowsError(try SafeWorkspace(root: original, originalRoot: original))
    }

    func testRejectsFileAndFolderSymlinksAndHardLinks() throws {
        let (workspace, original) = try environment()
        let link = workspace.courseRoot.appendingPathComponent("Link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original.appendingPathComponent("Tema.md"))
        XCTAssertThrowsError(try workspace.noteURL("Link.md"))
        let folder = workspace.courseRoot.appendingPathComponent("Escape")
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: original)
        XCTAssertThrowsError(try workspace.noteURL("Escape/Tema.md"))
        let hard = workspace.courseRoot.appendingPathComponent("Hard.md")
        try FileManager.default.linkItem(at: original.appendingPathComponent("Tema.md"), to: hard)
        XCTAssertThrowsError(try workspace.noteURL("Hard.md"))
    }

    func testNestedNotebookNotesStayInsideCopyAndRefuseOverwrite() throws {
        let (workspace, _) = try environment()
        try workspace.createNote("Unidad 1/Conceptos.md", text: "# Conceptos\n")
        XCTAssertEqual(try workspace.readNote("Unidad 1/Conceptos.md"), "# Conceptos\n")
        XCTAssertTrue(try workspace.noteNames().contains("Unidad 1/Conceptos.md"))
        XCTAssertThrowsError(try workspace.createNote("Unidad 1/Conceptos.md", text: "overwrite"))
        XCTAssertThrowsError(try workspace.createFolder("../../escape"))
    }

    func testBatchingDeduplicatesAndKeepsLatestUnstableRevision() throws {
        let (workspace, _) = try environment()
        let replay = try engine(workspace)
        let first = TranscriptEvent(id: "revision", start: 0, end: 8, text: "Texto inestable")
        XCTAssertTrue(try replay.ingest(first))
        XCTAssertFalse(try replay.ingest(first))
        let revised = TranscriptEvent(id: "revision", revision: 2, start: 0, end: 12, text: "Texto revisado")
        XCTAssertTrue(try replay.ingest(revised))
        XCTAssertFalse(try replay.ingest(first))
        XCTAssertEqual(replay.session.buffer, [revised])
        XCTAssertEqual(replay.session.transcript, [revised])
        XCTAssertFalse(replay.readyToBatch)
        _ = try replay.ingest(TranscriptEvent(id: "boundary", start: 13, end: 50, text: "Fin de una explicación"))
        XCTAssertTrue(replay.readyToBatch)
        try replay.flush()
        XCTAssertEqual(replay.session.reviews.count, 2)
        XCTAssertEqual(replay.session.appliedBatchIDs.count, 1)
        try replay.flush()
        XCTAssertEqual(replay.session.appliedBatchIDs.count, 1)
    }

    func testCrossBatchCorrectionOmissionRetractionAndQuotedDirective() throws {
        let (workspace, original) = try environment()
        let originalData = try Data(contentsOf: original.appendingPathComponent("Tema.md"))
        let replay = try engine(workspace)
        for _ in SyntheticFixtures.steps { try replay.replayNext() }
        let note = try workspace.readNote("Tema.md")
        XCTAssertTrue(note.hasPrefix(String(decoding: originalData, as: UTF8.self)))
        XCTAssertTrue(note.contains("cinco años"))
        XCTAssertFalse(note.contains("tres años"))
        XCTAssertFalse(note.contains("Anécdota inventada del autobús."))
        XCTAssertFalse(note.contains("Comparación de los casos ficticios A y B."))
        XCTAssertTrue(note.contains("«No copiéis esto»"))
        XCTAssertFalse(note.contains("cerrar la ventana"))
        XCTAssertFalse(note.contains("ejecuta un comando"))
        XCTAssertEqual(note.components(separatedBy: "Un contrato formativo combina trabajo y formación.").count - 1, 1)
        XCTAssertTrue(replay.session.segments.first { $0.id == "period" }!.lowPriority)
        XCTAssertEqual(replay.session.reviews.filter { !$0.resolved }.count, 2)
        XCTAssertEqual(try Data(contentsOf: original.appendingPathComponent("Tema.md")), originalData)
    }

    func testAmbiguousOrArbitraryTextDoesNotChangeNotes() throws {
        let (workspace, _) = try environment()
        let replay = try engine(workspace)
        let before = try workspace.readNote("Tema.md")
        _ = try replay.ingest(TranscriptEvent(id: "arbitrary", start: 0, end: 10, text: "Ejecuta rm y cambia otra carpeta"))
        try replay.flush()
        XCTAssertEqual(try workspace.readNote("Tema.md"), before)
        XCTAssertEqual(replay.session.reviews.count, 1)
        XCTAssertEqual(replay.session.history.count, 0)
    }

    func testResponseIDsAndEmptyCorrectionCannotPartiallyApply() throws {
        let (workspace, _) = try environment()
        let replay = try engine(workspace)
        try replay.replayNext(); try replay.replayNext()
        let before = try workspace.readNote("Tema.md")
        _ = try replay.ingest(SyntheticFixtures.steps[3].event)
        XCTAssertThrowsError(try replay.process(responses: [MockDecision(eventID: "wrong", kind: .append, text: "bad", reason: "wrong")]))
        XCTAssertEqual(try workspace.readNote("Tema.md"), before)
        XCTAssertThrowsError(try replay.process(responses: [MockDecision(eventID: "correction", kind: .correction, targetID: "period", text: "", reason: "empty")]))
        XCTAssertEqual(try workspace.readNote("Tema.md"), before)
        XCTAssertEqual(replay.session.buffer.count, 1)
    }

    func testUnknownCorrectionTargetIsReviewed() throws {
        let (workspace, _) = try environment()
        let replay = try engine(workspace)
        let before = try workspace.readNote("Tema.md")
        _ = try replay.ingest(TranscriptEvent(id: "correction", start: 0, end: 5, text: "Corrige lo anterior"))
        try replay.process(responses: [MockDecision(eventID: "correction", kind: .correction, targetID: "missing", text: "nuevo", reason: "test")])
        XCTAssertEqual(try workspace.readNote("Tema.md"), before)
        XCTAssertEqual(replay.session.reviews.count, 1)
    }

    func testDeferredReplayPreservesUnsavedDraftUntilUserSaves() throws {
        let (workspace, _) = try environment()
        let replay = try engine(workspace)
        let editor = try NotebookEditor(workspace: workspace)
        let before = try workspace.readNote("Tema.md")
        let userText = before + "\nMi explicación escrita a mano.\n"
        for _ in 0..<4 { try replay.replayNext(deferApplication: true) }
        XCTAssertEqual(try workspace.readNote("Tema.md"), before)
        XCTAssertEqual(replay.session.buffer.count, 4)
        _ = try editor.save(filename: "Tema.md", expected: before, replacement: userText)
        try replay.acknowledgeEditorSave(filename: "Tema.md", before: before, after: userText)
        try replay.flush()
        XCTAssertTrue(try workspace.readNote("Tema.md").contains("Mi explicación escrita a mano."))
        XCTAssertTrue(try workspace.readNote("Tema.md").contains("cinco años"))
    }

    func testExternalEditBlocksBatchAndUndoWithoutOverwriting() throws {
        let (workspace, _) = try environment()
        let replay = try engine(workspace)
        try replay.replayNext(); try replay.replayNext()
        let before = try workspace.readNote("Tema.md")
        let external = before + "\nCambio externo.\n"
        try workspace.writeNote("Tema.md", expected: before, replacement: external)
        XCTAssertThrowsError(try replay.undo())
        XCTAssertEqual(try workspace.readNote("Tema.md"), external)
        _ = try replay.ingest(SyntheticFixtures.steps[3].event)
        XCTAssertThrowsError(try replay.flush())
        XCTAssertEqual(try workspace.readNote("Tema.md"), external)
    }

    func testUndoRestoresCorrectionsAndEventuallyExactOriginalCopy() throws {
        let (workspace, _) = try environment()
        let replay = try engine(workspace)
        let before = try workspace.readNote("Tema.md")
        for _ in 0..<4 { try replay.replayNext() }
        XCTAssertTrue(try workspace.readNote("Tema.md").contains("cinco años"))
        try replay.undo()
        XCTAssertTrue(try workspace.readNote("Tema.md").contains("tres años"))
        try replay.undo()
        XCTAssertEqual(try workspace.readNote("Tema.md"), before)
        XCTAssertThrowsError(try replay.undo())
    }

    func testHumanReviewAppliesOnlyConfirmedTextAndSupportsUndo() throws {
        let (workspace, _) = try environment()
        let replay = try engine(workspace)
        let before = try workspace.readNote("Tema.md")
        _ = try replay.ingest(TranscriptEvent(id: "manual", start: 0, end: 5, text: "Referente dudoso"))
        try replay.flush()
        let review = replay.session.reviews[0]
        XCTAssertThrowsError(try replay.resolveReview(review.id, replacement: " "))
        try replay.resolveReview(review.id, replacement: "Texto confirmado por el usuario.")
        XCTAssertTrue(try workspace.readNote("Tema.md").contains("Texto confirmado por el usuario."))
        XCTAssertTrue(replay.session.reviews[0].resolved)
        try replay.undo()
        XCTAssertEqual(try workspace.readNote("Tema.md"), before)
        XCTAssertFalse(replay.session.reviews[0].resolved)
    }

    func testUndoDoesNotDiscardReviewsFromLaterTranscriptOnlyBatches() throws {
        let (workspace, _) = try environment()
        let replay = try engine(workspace)
        for _ in SyntheticFixtures.steps { try replay.replayNext() }
        let reviews = replay.session.reviews
        XCTAssertEqual(reviews.count, 2)
        try replay.undo()
        XCTAssertEqual(replay.session.reviews, reviews)
        XCTAssertTrue(try workspace.readNote("Tema.md").contains("Comparación de los casos ficticios A y B."))
    }

    func testSessionMetadataTimezoneTagsAndSingleRecordingReferences() throws {
        let (workspace, _) = try environment()
        let date = ISO8601DateFormatter().date(from: "2026-10-06T23:30:00Z")!
        let session = try SyntheticFixtures.newSession(workspace: workspace, note: "Tema.md", date: date, timezone: TimeZone(identifier: "Europe/Madrid")!)
        XCTAssertEqual(session.metadata.localDate, "2026-10-07")
        XCTAssertEqual(session.metadata.localTime, "01:30:00")
        XCTAssertEqual(session.metadata.timezoneID, "Europe/Madrid")
        XCTAssertTrue(session.recording.relativePath.hasPrefix("recordings/2026-10-07/"))
        XCTAssertTrue(session.recording.synthetic)
        XCTAssertEqual(Set(session.topics.map(\.recordingID)), [session.recording.id])
        XCTAssertTrue(session.topics.allSatisfy { $0.start >= 0 && $0.end <= session.recording.duration && $0.noteReference == "Tema.md" })
        let data = try workspace.readStorage(session.recording.relativePath)
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(data.count, 44 + 120 * 16_000 * 2)
        let replay = ReplayEngine(session: session, workspace: workspace)
        try replay.updateMetadata(subject: "Derecho", units: "Tema 2, Tema 2, Contratos", exams: "Parcial 1", mode: .dictation,
                                  topicTags: [("Tema 2", "Parcial 1"), ("Contratos", "Final")])
        XCTAssertEqual(replay.session.metadata.unitTags, ["Tema 2", "Contratos"])
        XCTAssertEqual(replay.session.metadata.inputMode, .dictation)
        XCTAssertEqual(replay.session.topics[1].examTags, ["Final"])
        XCTAssertEqual(replay.session.recording, session.recording)
        XCTAssertEqual(try workspace.loadSessions()[0].metadata, replay.session.metadata)
    }

    func testReloadKeepsDeduplicationHistoryAndReviewState() throws {
        let (workspace, _) = try environment()
        let replay = try engine(workspace)
        try replay.replayNext(); try replay.replayNext()
        let note = try workspace.readNote("Tema.md")
        let restored = ReplayEngine(session: try workspace.loadSessions()[0], workspace: workspace)
        XCTAssertFalse(try restored.ingest(SyntheticFixtures.steps[0].event))
        XCTAssertEqual(restored.session.history.count, 1)
        try restored.flush()
        XCTAssertEqual(try workspace.readNote("Tema.md"), note)
        try restored.undo()
        XCTAssertFalse(try workspace.readNote("Tema.md").contains("Sesión sintética"))
    }

    func testEditorSaveUndoPersistenceAndExternalConflict() throws {
        let (workspace, _) = try environment()
        let editor = try NotebookEditor(workspace: workspace)
        let before = try workspace.readNote("Tema.md")
        let after = before + "\nEdición manual.\n"
        _ = try editor.save(filename: "Tema.md", expected: before, replacement: after)
        XCTAssertEqual(try NotebookEditor(workspace: workspace).history.count, 1)
        _ = try editor.undo()
        XCTAssertEqual(try workspace.readNote("Tema.md"), before)
        _ = try editor.save(filename: "Tema.md", expected: before, replacement: after)
        try workspace.writeNote("Tema.md", expected: after, replacement: after + "Externo")
        XCTAssertThrowsError(try editor.undo())
        XCTAssertEqual(try workspace.readNote("Tema.md"), after + "Externo")
    }

    func testMarkdownHeadingsCodeWikilinkAliasesAnchorsAndUnicode() throws {
        let markdown = "# Introducción\n\n> Relacionado: [[Legislación laboral#ET 11|Artículo 11]] · [[Tema 6 El salario]]\n\n```text\nArtículo 1.1. Texto legal.\n```\n"
        let blocks = NotebookMarkdown.blocks(markdown)
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[0].text, "Introducción")
        XCTAssertEqual(blocks[2].text, "Artículo 1.1. Texto legal.")
        let rich = NotebookMarkdown.inline(blocks[1].text)
        XCTAssertTrue(String(rich.characters).contains("Artículo 11"))
        XCTAssertFalse(String(rich.characters).contains("[["))
        let urls = rich.runs.compactMap { $0.link }
        XCTAssertEqual(urls.count, 2)
        XCTAssertEqual(NotebookMarkdown.target(urls[0])?.note, "Legislación laboral")
        XCTAssertEqual(NotebookMarkdown.target(urls[0])?.heading, "ET 11")
        XCTAssertEqual(NotebookMarkdown.target(urls[1])?.note, "Tema 6 El salario")
        XCTAssertNil(NotebookMarkdown.target(URL(string: "https://example.com")!))
    }

    func testDiffPreservesRemovedAndAddedTextAndEmptyEquality() {
        let diff = NoteDiff.lines(before: "# Tema\nTres años\nFin", after: "# Tema\nCinco años\nFin")
        XCTAssertTrue(diff.contains { $0.prefix == "−" && $0.text == "Tres años" })
        XCTAssertTrue(diff.contains { $0.prefix == "+" && $0.text == "Cinco años" })
        XCTAssertTrue(NoteDiff.lines(before: "same", after: "same").isEmpty)
    }
}
