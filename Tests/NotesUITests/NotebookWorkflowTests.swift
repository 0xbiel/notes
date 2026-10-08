import XCTest
import LectureCore
@testable import Notes

final class NotebookWorkflowTests: XCTestCase {
    @MainActor private func environment() throws -> (Workbench, URL) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".test-workspaces/Notebook-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("copied-course"), withIntermediateDirectories: true)
        try Data("# Inicio\n\nNota inventada.\n".utf8).write(to: root.appendingPathComponent("copied-course/Inicio.md"))
        try JSONSerialization.data(withJSONObject: ["originalRoot": root.appendingPathComponent("original").path]).write(to: root.appendingPathComponent("original-hashes.json"))
        let model = Workbench(workspaceRoot: root)
        XCTAssertNil(model.errorText)
        return (model, root)
    }

    @MainActor func testProviderPreferencesDraftValidationSaveDiscardAndFailure() async throws {
        let (model, root) = try environment()
        defer { model.media?.shutdown(); model.ai?.stop(); try? FileManager.default.removeItem(at: root) }
        let ai = try XCTUnwrap(model.ai)
        let preferences = ProviderPreferencesModel(ai: ai)
        preferences.draft.selectedProvider = .codexCLI
        preferences.draft.codexCLI.model = "example-model"
        XCTAssertEqual(ai.providerSettings.selectedProvider, .openCode)
        preferences.draft.codexCLI.executablePath = "relative/path"
        preferences.save()
        XCTAssertNotNil(preferences.error)
        XCTAssertEqual(ai.providerSettings.selectedProvider, .openCode)
        preferences.draft.codexCLI.executablePath = "/missing/codex"
        preferences.save()
        XCTAssertNil(preferences.error)
        XCTAssertFalse(preferences.hasChanges)
        let reopened = ProviderPreferencesModel(ai: ai)
        XCTAssertEqual(reopened.draft.codexCLI.model, "example-model")
        reopened.draft.codexCLI.model = "changed-model"
        reopened.discard()
        XCTAssertEqual(reopened.draft.codexCLI.model, "example-model")
        await reopened.checkInstallation()
        XCTAssertNotNil(reopened.error)
        XCTAssertNil(reopened.diagnostic)
        XCTAssertFalse(reopened.checking)
        XCTAssertEqual(try AIProviderSettings.load(in: XCTUnwrap(model.workspace)).codexCLI.executablePath, "/missing/codex")
        XCTAssertTrue(ai.outbox.batches.isEmpty)
    }

    @MainActor func testModelSelectionFavoritesVisibilityAndCustomModelsSurviveReload() throws {
        let (model, root) = try environment()
        defer { model.media?.shutdown(); model.ai?.stop(); try? FileManager.default.removeItem(at: root) }
        let ai = try XCTUnwrap(model.ai)
        let preferences = ProviderPreferencesModel(ai: ai)
        preferences.draft.selectedProvider = .codexCLI
        preferences.addCustomModel("example-a")
        preferences.addCustomModel("example-b")
        preferences.addCustomModel("example-c")
        preferences.move("example-b", offset: -1)
        XCTAssertEqual(preferences.models.first?.id, "example-b")
        preferences.favorite("example-c")
        XCTAssertEqual(preferences.models.first?.id, "example-c")
        preferences.selectModel("example-b")
        preferences.hide("example-a")
        preferences.draft.selected.reasoningEffort = "low"
        preferences.save()
        XCTAssertNil(preferences.error)
        let saved = try AIProviderSettings.load(in: XCTUnwrap(model.workspace))
        XCTAssertEqual(saved.selected.model, "example-b")
        XCTAssertEqual(saved.selected.reasoningEffort, "low")
        XCTAssertEqual(saved.modelPreferences?["codexCLI"]?.favorites, ["example-c"])
        XCTAssertEqual(saved.modelPreferences?["codexCLI"]?.hidden, ["example-a"])
        XCTAssertEqual(saved.modelPreferences?["codexCLI"]?.custom.count, 3)
        preferences.removeCustomModel("example-b")
        XCTAssertEqual(preferences.draft.selected.model, "default")
        preferences.discard()
        XCTAssertEqual(preferences.draft.selected.model, "example-b")
        preferences.addCustomModel("bad --flag")
        XCTAssertNotNil(preferences.error)
        XCTAssertEqual(preferences.models.count, 3)
    }

    @MainActor func testProviderSettingsReloadConsentAndQueuedSnapshotIsolation() throws {
        let (model, root) = try environment()
        defer { model.media?.shutdown(); model.ai?.stop(); try? FileManager.default.removeItem(at: root) }
        model.createAIDemo()
        let ai = try XCTUnwrap(model.ai)
        let media = try XCTUnwrap(model.media?.selected)
        var settings = ai.providerSettings
        settings.selectedProvider = .codexCLI
        try ai.saveProviderSettings(settings)
        ai.send(media: media, ids: Set(media.transcript.map(\.id)))
        XCTAssertNotNil(ai.error)
        XCTAssertTrue(ai.outbox.batches.isEmpty)
        XCTAssertFalse(ai.running)
        settings.codexCLI.accountSendingAllowed = true
        settings.codexCLI.model = "example-model"
        try ai.saveProviderSettings(settings)
        var pending = try ai.outbox.enqueue(media: media, selected: media.transcript)
        pending.providerConfiguration = settings.selected
        pending.model = settings.selected.model
        try ai.outbox.replace(pending)
        settings.selectedProvider = .openCode
        try ai.saveProviderSettings(settings)
        let restored = Workbench(workspaceRoot: root)
        defer { restored.media?.shutdown(); restored.ai?.stop() }
        XCTAssertNil(restored.errorText)
        XCTAssertEqual(restored.ai?.providerSettings.selectedProvider, .openCode)
        XCTAssertEqual(restored.ai?.providerSettings.codexCLI.model, "example-model")
        XCTAssertEqual(restored.ai?.batches.first?.providerConfiguration?.provider, .codexCLI)
        XCTAssertEqual(restored.ai?.batches.first?.model, "example-model")
        ai.running = true
        XCTAssertThrowsError(try ai.saveProviderSettings(settings))
        ai.running = false
    }

    @MainActor func testNotebookFolderDraftSwitchSaveAndReload() throws {
        let (model, root) = try environment()
        defer { model.media?.shutdown(); model.ai?.stop(); try? FileManager.default.removeItem(at: root) }
        try model.createNotebookItem(kind: "cuaderno", name: "Prueba café 👩🏽‍💻")
        let notebookID = model.selectedNotebookID
        let startNote = try XCTUnwrap(model.selectedNote)
        try model.createNotebookItem(kind: "carpeta", name: "Unidad 1")
        try model.createNotebookItem(kind: "nota", name: "Unidad 1/Correcciones")
        let note = try XCTUnwrap(model.selectedNote)
        let text = "# Correcciones\n\n**Acción** y niño 👩🏽‍💻.\n\n- Dos pasos, no tres.\n\n```swift\nlet café = 2\n```\n"
        model.changeDraft(text)
        XCTAssertTrue(model.isDirty)
        model.openNote(startNote)
        model.openNote(note)
        XCTAssertEqual(model.draftText, text)
        model.saveDraft()
        XCTAssertNil(model.errorText)
        XCTAssertFalse(model.isDirty)
        XCTAssertEqual(try model.workspace?.readNote(note), text)
        XCTAssertThrowsError(try model.createNotebookItem(kind: "cuaderno", name: "Prueba café 👩🏽‍💻"))
        XCTAssertThrowsError(try model.createNotebookItem(kind: "nota", name: "Unidad 1/Correcciones"))
        XCTAssertEqual(try model.workspace?.readNote(note), text)
        let restored = Workbench(workspaceRoot: root)
        defer { restored.media?.shutdown(); restored.ai?.stop() }
        restored.openNote(note)
        XCTAssertNil(restored.errorText)
        XCTAssertEqual(restored.selectedNotebookID, notebookID)
        XCTAssertEqual(restored.draftText, text)
        XCTAssertFalse(restored.isDirty)
    }

    @MainActor func testGeneratedProposalReviewDirtyGuardApplyUndoAndReload() throws {
        let (model, root) = try environment()
        defer { model.media?.shutdown(); model.ai?.stop(); try? FileManager.default.removeItem(at: root) }
        model.createAIDemo()
        XCTAssertNil(model.errorText)
        let media = try XCTUnwrap(model.media?.selected)
        let ai = try XCTUnwrap(model.ai)
        var batch = try ai.outbox.enqueue(media: media, selected: [media.transcript[0]])
        let response: [String: Any] = ["version": 1, "batch_id": batch.id, "decisions": [["source_ids": ["s1"], "action": "correct", "text": "El concepto A utiliza dos pasos.", "reason": "Corrección explícita inventada.", "target_quote": "El concepto A utiliza tres pasos."]]]
        batch.decisions = try OpenRouterHarness.decodeResponse(String(decoding: JSONSerialization.data(withJSONObject: response), as: UTF8.self), for: batch)
        batch.stage = .ready
        try ai.outbox.replace(batch)
        ai.refresh()
        let proposal = try XCTUnwrap(batch.decisions.first)
        XCTAssertEqual(try model.workspace?.readNote(media.targetNote), SyntheticAIFixture.note)
        model.changeDraft(SyntheticAIFixture.note + "\nBorrador sin guardar.\n")
        model.applyAI(batch: batch, proposal: proposal, text: proposal.text, quote: proposal.targetQuote)
        XCTAssertNotNil(model.errorText)
        XCTAssertTrue(model.draftText.contains("Borrador sin guardar"))
        XCTAssertEqual(try model.workspace?.readNote(media.targetNote), SyntheticAIFixture.note)
        model.changeDraft(SyntheticAIFixture.note)
        model.errorText = nil
        model.applyAI(batch: batch, proposal: proposal, text: proposal.text, quote: proposal.targetQuote)
        XCTAssertNil(model.errorText)
        XCTAssertTrue(model.draftText.contains("dos pasos"))
        XCTAssertFalse(model.isDirty)
        let restored = Workbench(workspaceRoot: root)
        defer { restored.media?.shutdown(); restored.ai?.stop() }
        restored.openNote(media.targetNote)
        XCTAssertTrue(restored.draftText.contains("dos pasos"))
        XCTAssertNotNil(restored.ai?.batches.first?.decisions.first?.resolution)
        restored.undoEditor()
        XCTAssertNil(restored.errorText)
        XCTAssertEqual(restored.draftText, SyntheticAIFixture.note)
        XCTAssertEqual(try restored.workspace?.readNote(media.targetNote), SyntheticAIFixture.note)
        XCTAssertNil(restored.ai?.batches.first?.decisions.first?.resolution)
    }
}
