import XCTest
@testable import LectureCore

final class GenerationIntegrationTests: XCTestCase {
    func testLiveConnectionProbeWithSelectedModel() async throws {
        guard ProcessInfo.processInfo.environment["NOTES_CONNECTION_PROBE"] == "1" else {
            throw XCTSkip("Set NOTES_CONNECTION_PROBE=1 to send an invented Codex connection probe.")
        }
        var configuration = AIProviderSettings().codexCLI
        configuration.model = "gpt-6-luna"; configuration.reasoningEffort = "low"; configuration.fastMode = true
        let result = try await ProviderConnectionTest.run(configuration)
        XCTAssertEqual(result.model, "gpt-6-luna")
        XCTAssertEqual(result.provider, .codexCLI)
        XCTAssertGreaterThan(result.elapsedSeconds, 0)
        XCTAssertFalse(configuration.accountSendingAllowed)
    }

    func testLiveCodexInventedGeneration() async throws { try await accountGeneration(.codexCLI) }
    func testLiveAntigravityInventedGeneration() async throws { try await accountGeneration(.antigravity) }

    private func accountGeneration(_ provider: NotesAIProvider) async throws {
        guard ProcessInfo.processInfo.environment["NOTES_ACCOUNT_AI_DEMO"]?.split(separator: ",").contains(Substring(provider.rawValue)) == true else {
            throw XCTSkip("Set NOTES_ACCOUNT_AI_DEMO to codexCLI and/or antigravity to send the invented fixture through an existing account.")
        }
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/notes-provider-tests/AccountGeneration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("copied-course"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try SafeWorkspace(root: root, originalRoot: root.appendingPathComponent("original"))
        try workspace.createNote("Inventado.md", text: SyntheticAIFixture.note)
        var media = MediaJob(notebookID: "synthetic", subject: "Invented demo", note: "Inventado.md", sourceName: "Invented text only")
        media.transcript = SyntheticAIFixture.segments
        let outbox = try AIOutbox(workspace: workspace)
        var batch = try outbox.enqueue(media: media, selected: media.transcript)
        XCTAssertTrue(SyntheticAIFixture.matches(batch))
        var configuration = AIProviderSettings().configuration(for: provider)
        if provider == .codexCLI, let model = ProcessInfo.processInfo.environment["NOTES_CODEX_DEMO_MODEL"] {
            configuration.model = model; configuration.reasoningEffort = "low"
        }
        configuration.accountSendingAllowed = true
        batch.providerConfiguration = configuration; batch.model = configuration.model
        defer { XCTAssertEqual(try? workspace.readNote("Inventado.md"), SyntheticAIFixture.note) }
        let result = try await NotesProviderTransport(store: LocalMediaStore(workspace: workspace)).send(batch, configuration: configuration)
        XCTAssertEqual(result.stage, .ready)
        XCTAssertNil(result.reportedCost)
        XCTAssertFalse(result.decisions.isEmpty)
        XCTAssertEqual(try workspace.readNote("Inventado.md"), SyntheticAIFixture.note)
        let correction = try XCTUnwrap(result.decisions.first { $0.action == .correct })
        try outbox.replace(result)
        let editor = try NotebookEditor(workspace: workspace)
        _ = try outbox.apply(batchID: result.id, proposalID: correction.id, text: correction.text, quote: correction.targetQuote, editor: editor, hasDraft: false)
        XCTAssertNotEqual(try workspace.readNote("Inventado.md"), SyntheticAIFixture.note)
        _ = try editor.undo()
    }

    func testLiveInventedGenerationLeavesNoteUntouchedUntilReview() async throws {
        guard ProcessInfo.processInfo.environment["NOTES_AI_DEMO"] == "1" else {
            throw XCTSkip("Set NOTES_AI_DEMO=1 to send only the exact public invented fixture through the zero-price, retention-permitted demo route.")
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".test-workspaces/Generation-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("copied-course"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let workspace = try SafeWorkspace(root: root, originalRoot: root.appendingPathComponent("original"))
        try workspace.createNote("Inventado.md", text: SyntheticAIFixture.note)
        var media = MediaJob(notebookID: "synthetic", subject: "Invented demo", note: "Inventado.md", sourceName: "Invented text only")
        media.transcript = SyntheticAIFixture.segments
        let outbox = try AIOutbox(workspace: workspace)
        let batch = try outbox.enqueue(media: media, selected: media.transcript)
        XCTAssertTrue(SyntheticAIFixture.matches(batch))
        let harness = OpenRouterHarness(store: LocalMediaStore(workspace: workspace))
        let result: AIBatch
        do {
            result = try await harness.sendSyntheticDemo(batch, syntheticEvidence: { evidence in
                if let path = ProcessInfo.processInfo.environment["NOTES_AI_EVIDENCE"] {
                    try evidence.write(to: URL(fileURLWithPath: path), options: .atomic)
                }
            })
        } catch {
            XCTAssertEqual(try workspace.readNote("Inventado.md"), SyntheticAIFixture.note)
            XCTAssertTrue(try NotebookEditor(workspace: workspace).history.isEmpty)
            throw error
        }
        XCTAssertEqual(result.stage, .ready)
        XCTAssertEqual(result.reportedCost, 0)
        XCTAssertFalse(result.decisions.isEmpty)
        XCTAssertEqual(try workspace.readNote("Inventado.md"), SyntheticAIFixture.note)
        let correction = try XCTUnwrap(result.decisions.first { $0.action == .correct })
        XCTAssertTrue(correction.text.lowercased().contains("dos pasos"))
        var reviewed = result
        reviewed.stage = .ready
        try outbox.replace(reviewed)
        let editor = try NotebookEditor(workspace: workspace)
        _ = try outbox.apply(batchID: reviewed.id, proposalID: correction.id, text: correction.text, quote: correction.targetQuote, editor: editor, hasDraft: false)
        XCTAssertTrue(try workspace.readNote("Inventado.md").contains("dos pasos"))
        _ = try editor.undo()
        XCTAssertEqual(try workspace.readNote("Inventado.md"), SyntheticAIFixture.note)
    }
}
