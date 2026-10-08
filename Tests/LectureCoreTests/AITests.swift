import XCTest
@testable import LectureCore

final class AITests: XCTestCase {
    func environment() throws -> (SafeWorkspace, MediaJob, AIOutbox) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".test-workspaces/AI-\(UUID().uuidString)")
        let original = root.appendingPathComponent("original")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("copied-course"), withIntermediateDirectories: true)
        let note = "# Ejemplo inventado\n\nEl concepto A utiliza tres pasos.\n\n" + String(repeating: "contenido ajeno secreto ", count: 300)
        try Data(note.utf8).write(to: root.appendingPathComponent("copied-course/Tema.md"))
        try Data(note.utf8).write(to: original.appendingPathComponent("Tema.md"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let workspace = try SafeWorkspace(root: root, originalRoot: original)
        var media = MediaJob(notebookID: "test", subject: "Inventado", note: "Tema.md", sourceName: "synthetic-only")
        media.transcript = [MediaTranscriptSegment(id: "span1", start: 0, end: 45, text: "Corrijo el concepto A: utiliza dos pasos. No copiéis este inciso: mañana llueve. El concepto B también es importante.")]
        return (workspace, media, try AIOutbox(workspace: workspace))
    }
    func response(_ batch: AIBatch, action: String = "correct", quote: String = "El concepto A utiliza tres pasos.") throws -> String {
        let object: [String: Any] = ["version": 1, "batch_id": batch.id, "decisions": [["source_ids": ["span1"], "action": action, "text": "El concepto A utiliza dos pasos.", "reason": "Corrección explícita del ejemplo inventado.", "target_quote": quote]]]
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
    func ready(_ outbox: AIOutbox, _ media: MediaJob) throws -> AIBatch {
        var batch = try outbox.enqueue(media: media, selected: media.transcript)
        batch.decisions = try OpenRouterHarness.decodeResponse(response(batch), for: batch); batch.stage = .ready
        try outbox.replace(batch); return batch
    }
    func testPayloadMinimizationAndStableDedupAndBoundedGroups() throws {
        let (_, media, outbox) = try environment()
        let batch = try outbox.enqueue(media: media, selected: media.transcript)
        XCTAssertEqual(try outbox.enqueue(media: media, selected: media.transcript).id, batch.id)
        let payload = String(decoding: try OpenRouterHarness.payload(batch), as: UTF8.self)
        XCTAssertTrue(payload.contains("span1")); XCTAssertTrue(payload.contains("tres pasos"))
        XCTAssertFalse(payload.contains("contenido ajeno secreto")); XCTAssertFalse(payload.contains("Tema.md")); XCTAssertFalse(payload.contains(outbox.workspace.originalRoot.path))
        XCTAssertLessThanOrEqual(batch.context.count, 2000)
        XCTAssertTrue(AIOutbox.groups(media.transcript, flush: false).isEmpty)
        let small = [MediaTranscriptSegment(id: "a", start: 0, end: 2, text: "Un inciso")]
        XCTAssertTrue(AIOutbox.groups(small, flush: false).isEmpty); XCTAssertEqual(AIOutbox.groups(small, flush: true).count, 1)
    }
    func testQueueBackpressureAndInterruptedRecoveryDoesNotRetry() throws {
        let (workspace, media, outbox) = try environment()
        for i in 0..<20 { var segment = media.transcript[0]; segment.id = "\(i)"; _ = try outbox.enqueue(media: media, selected: [segment]) }
        XCTAssertThrowsError(try outbox.enqueue(media: media, selected: [.init(id: "overflow", start: 0, end: 2, text: "Persistirá en transcripción")]))
        var batch = outbox.batches[0]; batch.stage = .sending; try outbox.replace(batch)
        let recovered = try AIOutbox(workspace: workspace)
        XCTAssertEqual(recovered.batches.first?.stage, .interrupted); XCTAssertEqual(recovered.batches.count, 20)
    }
    func testStrictSchemaUnknownIDsCommandsAndUnverifiableCorrection() throws {
        let (_, media, outbox) = try environment(); let batch = try outbox.enqueue(media: media, selected: media.transcript)
        let valid = try response(batch)
        XCTAssertThrowsError(try OpenRouterHarness.decodeResponse(valid.replacingOccurrences(of: "span1", with: "unknown"), for: batch))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(valid.utf8)) as? [String: Any]); object["command"] = "rm something"
        XCTAssertThrowsError(try OpenRouterHarness.decodeResponse(String(decoding: JSONSerialization.data(withJSONObject: object), as: UTF8.self), for: batch))
        let uncertain = try OpenRouterHarness.decodeResponse(response(batch, quote: "nonexistent quote"), for: batch)
        XCTAssertEqual(uncertain.first?.action, .uncertain)
        XCTAssertEqual(try OpenRouterHarness.decodeResponse("```json\n" + valid + "\n```", for: batch).count, 1)
    }
    func testEffectiveConfigurationFailClosedOnOverrides() throws {
        var config = OpenRouterHarness.config()
        XCTAssertNoThrow(try OpenRouterHarness.verifyConfig(JSONSerialization.data(withJSONObject: config)))
        config["small_model"] = "paid/model"
        XCTAssertThrowsError(try OpenRouterHarness.verifyConfig(JSONSerialization.data(withJSONObject: config)))
        config = OpenRouterHarness.config(); config["permission"] = ["*": "allow"]
        XCTAssertThrowsError(try OpenRouterHarness.verifyConfig(JSONSerialization.data(withJSONObject: config)))
        config = OpenRouterHarness.config(); config["mcp"] = ["external": ["enabled": true]]
        XCTAssertThrowsError(try OpenRouterHarness.verifyConfig(JSONSerialization.data(withJSONObject: config)))
        config = OpenRouterHarness.config()
        var providers = try XCTUnwrap(config["provider"] as? [String: [String: Any]])
        providers["openrouter"]?["options"] = ["baseURL": "https://example.invalid"]
        config["provider"] = providers
        XCTAssertThrowsError(try OpenRouterHarness.verifyConfig(JSONSerialization.data(withJSONObject: config)))
    }
    func testExitZeroAPIErrorAndTruncatedOrPaidReplyAreRejected() throws {
        let (_, media, outbox) = try environment(); let batch = try outbox.enqueue(media: media, selected: media.transcript)
        XCTAssertThrowsError(try OpenRouterHarness.decodeEvents(Data(#"{"type":"error","error":{"name":"APIError","data":{"statusCode":403}}}"#.utf8), for: batch))
        let text: [String: Any] = ["type": "text", "part": ["text": try response(batch)]]
        let first = String(decoding: try JSONSerialization.data(withJSONObject: text), as: UTF8.self)
        for part: [String: Any] in [["reason": "length", "cost": 0], ["reason": "stop", "cost": 0.1], ["reason": "stop"]] {
            let finish = String(decoding: try JSONSerialization.data(withJSONObject: ["type": "step_finish", "part": part]), as: UTF8.self)
            XCTAssertThrowsError(try OpenRouterHarness.decodeEvents(Data((first + "\n" + finish).utf8), for: batch))
        }
        let finish = #"{"type":"step_finish","part":{"reason":"stop","cost":0}}"#
        XCTAssertEqual(try OpenRouterHarness.decodeEvents(Data((first + "\n" + finish).utf8), for: batch).stage, .ready)
    }
    func testApplyConflictDirtyGuardDedupUndoAndOriginalPreserved() throws {
        let (workspace, media, outbox) = try environment(); let editor = try NotebookEditor(workspace: workspace); let batch = try ready(outbox, media); let proposal = batch.decisions[0]
        let original = try Data(contentsOf: workspace.originalRoot.appendingPathComponent("Tema.md"))
        XCTAssertThrowsError(try outbox.apply(batchID: batch.id, proposalID: proposal.id, text: proposal.text, quote: proposal.targetQuote, editor: editor, hasDraft: true))
        let change = try outbox.apply(batchID: batch.id, proposalID: proposal.id, text: proposal.text, quote: proposal.targetQuote, editor: editor, hasDraft: false)
        XCTAssertTrue(try workspace.readNote("Tema.md").contains("dos pasos")); XCTAssertEqual(editor.history.count, 1)
        XCTAssertThrowsError(try outbox.apply(batchID: batch.id, proposalID: proposal.id, text: proposal.text, quote: proposal.targetQuote, editor: editor, hasDraft: false))
        _ = try editor.undo(); try outbox.acknowledgeAppEdit(filename: change.filename, before: change.after, after: change.before); try outbox.recoverApplications(editor: editor)
        XCTAssertEqual(try workspace.readNote("Tema.md"), change.before); XCTAssertNil(outbox.batches[0].decisions[0].resolution)
        try outbox.dismiss(batchID: batch.id, proposalID: proposal.id); try outbox.recoverApplications(editor: editor)
        XCTAssertEqual(outbox.batches[0].decisions[0].resolution, "excluded")
        XCTAssertEqual(try Data(contentsOf: workspace.originalRoot.appendingPathComponent("Tema.md")), original)
    }
    func testManualEditConflictCannotOverwriteAndCanCreateFreshBatch() throws {
        let (workspace, media, outbox) = try environment(); let editor = try NotebookEditor(workspace: workspace); let batch = try ready(outbox, media); let decision = batch.decisions[0]
        _ = try editor.save(filename: batch.targetNote, expected: batch.expectedNote, replacement: batch.expectedNote + "\nUser edit\n")
        XCTAssertThrowsError(try outbox.apply(batchID: batch.id, proposalID: decision.id, text: decision.text, quote: decision.targetQuote, editor: editor, hasDraft: false))
        XCTAssertTrue(try workspace.readNote(batch.targetNote).contains("User edit"))
        XCTAssertNotEqual(try outbox.enqueue(media: media, selected: media.transcript).id, batch.id)
    }
    func testRetentionPermittedDemoRequiresExactInventedContent() async throws {
        let (workspace, media, outbox) = try environment()
        let batch = try outbox.enqueue(media: media, selected: media.transcript)
        XCTAssertFalse(SyntheticAIFixture.matches(batch))
        do { _ = try await OpenRouterHarness(store: LocalMediaStore(workspace: workspace)).sendSyntheticDemo(batch); XCTFail("Private-like batch accepted into demo route") }
        catch { XCTAssertTrue(error.localizedDescription.contains("fixture inventada exacta")) }
        XCTAssertEqual(OpenRouterHarness.policy["zdr"] as? Bool, true)
        XCTAssertEqual(OpenRouterHarness.syntheticDemoPolicy["zdr"] as? Bool, false)
        XCTAssertEqual(OpenRouterHarness.syntheticDemoPolicy["data_collection"] as? String, "deny")
        XCTAssertNoThrow(try OpenRouterHarness.verifyConfig(JSONSerialization.data(withJSONObject: OpenRouterHarness.config(syntheticDemo: true)), syntheticDemo: true))
        XCTAssertThrowsError(try OpenRouterHarness.verifyConfig(JSONSerialization.data(withJSONObject: OpenRouterHarness.config(syntheticDemo: true))))
        var exact = batch; exact.notebookID = "synthetic"; exact.expectedNote = SyntheticAIFixture.note; exact.segments = SyntheticAIFixture.segments; exact.priorSegments = []; exact.context = AIOutbox.relevantContext(note: SyntheticAIFixture.note, selected: SyntheticAIFixture.segments)
        XCTAssertTrue(SyntheticAIFixture.matches(exact))
        exact.context += "\nPrivate note excerpt"; XCTAssertFalse(SyntheticAIFixture.matches(exact))
    }
}
