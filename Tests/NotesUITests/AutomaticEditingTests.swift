import XCTest
@testable import LectureCore
@testable import Notes

final class AutomaticEditingTests: XCTestCase {
    @MainActor private func fixture(_ policy: AIEditAutonomy?, _ action: AIAction = .add) throws -> (Workbench, AIBatch, URL) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".test-workspaces/Auto-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("copied-course"), withIntermediateDirectories: true)
        try Data("# Nota\n\nTexto inicial.\n".utf8).write(to: root.appendingPathComponent("copied-course/Nota.md"))
        try JSONSerialization.data(withJSONObject: ["originalRoot": root.appendingPathComponent("original").path]).write(to: root.appendingPathComponent("original-hashes.json"))
        let model = Workbench(workspaceRoot: root)
        model.openNote("Nota.md")
        let ai = try XCTUnwrap(model.ai)
        ai.providerSettings.editAutonomy = policy
        var media = MediaJob(notebookID: "test", subject: "Test", note: "Nota.md", sourceName: "Invented")
        media.transcript = [.init(id: "s1", start: 0, end: 10, text: "Contenido inventado para probar permisos.")]
        var batch = try ai.outbox.enqueue(media: media, selected: media.transcript)
        batch.stage = .ready; batch.editAutonomy = policy
        batch.decisions = [.init(id: UUID().uuidString, sourceIDs: ["s1"], action: action, text: "Texto nuevo.", reason: "Prueba", targetQuote: action == .correct || action == .retract ? "Texto inicial." : nil)]
        try ai.outbox.replace(batch)
        addTeardownBlock { @MainActor in model.media?.shutdown(); model.ai?.stop(); try? FileManager.default.removeItem(at: root) }
        return (model, batch, root)
    }

    @MainActor func testAdditionUpdatesOpenEditorPersistsAndUndoes() throws {
        let (model, batch, root) = try fixture(.additions)
        try XCTUnwrap(model.ai).applyAutomatic(batch)
        XCTAssertTrue(model.draftText.contains("Texto nuevo.")); XCTAssertFalse(model.isDirty)
        let restored = Workbench(workspaceRoot: root)
        defer { restored.media?.shutdown(); restored.ai?.stop() }
        restored.openNote("Nota.md")
        XCTAssertTrue(restored.draftText.contains("Texto nuevo."))
        restored.undoEditor()
        XCTAssertEqual(restored.draftText, "# Nota\n\nTexto inicial.\n")
    }

    @MainActor func testPermissionLevelsAndNoEscalationOfQueuedBatches() throws {
        for policy in [AIEditAutonomy.review, .additions, .edits] {
            let (model, batch, _) = try fixture(policy, .correct)
            try XCTUnwrap(model.ai).applyAutomatic(batch)
            XCTAssertEqual(model.draftText.contains("Texto nuevo."), policy == .edits)
        }
        let (legacy, batch, _) = try fixture(nil)
        legacy.ai?.providerSettings.editAutonomy = .edits
        try XCTUnwrap(legacy.ai).applyAutomatic(batch)
        XCTAssertFalse(legacy.draftText.contains("Texto nuevo."))
        let (restricted, pending, _) = try fixture(.edits)
        restricted.ai?.providerSettings.editAutonomy = .review
        try XCTUnwrap(restricted.ai).applyAutomatic(pending)
        XCTAssertFalse(restricted.draftText.contains("Texto nuevo."))
    }

    @MainActor func testDraftConflictUncertaintyAndOverlapStayUntouched() throws {
        let (dirty, batch, _) = try fixture(.edits)
        dirty.changeDraft("Borrador pendiente")
        XCTAssertThrowsError(try XCTUnwrap(dirty.ai).applyAutomatic(batch))
        XCTAssertEqual(dirty.draftText, "Borrador pendiente")
        let (stale, pending, _) = try fixture(.edits)
        try stale.workspace?.writeNote("Nota.md", expected: pending.expectedNote, replacement: "Cambio externo")
        XCTAssertThrowsError(try XCTUnwrap(stale.ai).applyAutomatic(pending))
        let (uncertain, doubtful, _) = try fixture(.edits, .uncertain)
        try XCTUnwrap(uncertain.ai).applyAutomatic(doubtful)
        XCTAssertFalse(uncertain.draftText.contains("Texto nuevo."))
        let (overlap, original, _) = try fixture(.edits)
        var overlapping = original; overlapping.segments[0].boundaryReview = true
        try overlap.ai?.outbox.replace(overlapping)
        try XCTUnwrap(overlap.ai).applyAutomatic(overlapping)
        XCTAssertFalse(overlap.draftText.contains("Texto nuevo."))
    }
}
