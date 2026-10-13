import XCTest
@testable import LectureCore

final class ProviderTests: XCTestCase {
    func testNotebookRetentionRequiresExplicitOptInAndKeepsFreeTrainingPolicy() throws {
        func policy(_ configuration: [String: Any]) throws -> [String: Any] {
            let providers = try XCTUnwrap(configuration["provider"] as? [String: [String: Any]])
            let models = try XCTUnwrap(providers["openrouter"]?["models"] as? [String: [String: Any]])
            let options = try XCTUnwrap(models["openrouter/free"]?["options"] as? [String: Any])
            return try XCTUnwrap(options["provider"] as? [String: Any])
        }
        XCTAssertEqual(try policy(OpenRouterHarness.config(notebookEditing: true))["zdr"] as? Bool, true)
        let optedIn = OpenRouterHarness.config(notebookEditing: true, allowRetention: true)
        let actual = try policy(optedIn)
        XCTAssertEqual(actual["zdr"] as? Bool, false)
        XCTAssertEqual(actual["data_collection"] as? String, "deny")
        XCTAssertEqual(actual["max_price"] as? [String: Int], ["prompt": 0, "completion": 0])
        let encoded = try JSONSerialization.data(withJSONObject: optedIn)
        XCTAssertNoThrow(try OpenRouterHarness.verifyConfig(encoded, notebookEditing: true, allowRetention: true))
        XCTAssertThrowsError(try OpenRouterHarness.verifyConfig(encoded, notebookEditing: true))
        XCTAssertEqual(try policy(OpenRouterHarness.config(allowRetention: true))["zdr"] as? Bool, true)
    }

    func testProviderFailureReportsRetentionBlockWithoutLeakingRawMetadata() throws {
        let data = try JSONSerialization.data(withJSONObject: ["type": "error", "error": ["data": ["statusCode": 404, "message": "No endpoints found matching your data policy (Zero data retention)", "responseHeaders": ["set-cookie": "private-cookie"]]]])
        let message = try XCTUnwrap(OpenRouterHarness.providerFailure(data))
        XCTAssertTrue(message.contains("zero data retention"))
        XCTAssertFalse(message.contains("private-cookie"))
        XCTAssertThrowsError(try OpenRouterHarness.decodeTextEvents(data))
    }

    func testProgressOnlyPublishesProviderReasoningAndLifecycle() throws {
        let thought = Data(#"{"type":"reasoning","part":{"id":"r1","text":"Checking the requested sources."}}"#.utf8)
        XCTAssertEqual(NotebookProviderProgress.decode(thought)?.detail, "Checking the requested sources.")
        let response = Data(#"{"type":"text","part":{"text":"{private response JSON}"}}"#.utf8)
        XCTAssertNil(NotebookProviderProgress.decode(response)?.detail)
        XCTAssertEqual(NotebookProviderProgress.decode(response)?.title, "Redactando respuesta…")
        XCTAssertNil(NotebookProviderProgress.decode(Data(#"{"type":"error","error":{"token":"secret"}}"#.utf8)))
        let codex = Data(#"{"type":"item.completed","item":{"id":"c1","type":"reasoning","text":"Checking the math."}}"#.utf8)
        XCTAssertEqual(NotebookProviderProgress.decode(codex)?.id, "thought-c1")
    }

    func testProgressArrivesBeforeProcessExitsAndPreservesCompleteOutput() async throws {
        let command = NotesProcess(timeoutInterval: 5)
        command.process.executableURL = URL(fileURLWithPath: "/bin/sh")
        let line = #"{"type":"reasoning","part":{"id":"r1","text":"Checking sources."}}"#
        command.process.arguments = ["-c", "printf '%s\\n' '" + line + "'; sleep 1; printf '%s' '{\"type\":\"text\",\"part\":{\"text\":\"done\"}}'"]
        let update = expectation(description: "Live reasoning")
        let data = try await command.runStreaming { event in
            if event.detail != nil {
                XCTAssertTrue(command.process.isRunning)
                XCTAssertEqual(event.detail, "Checking sources.")
                update.fulfill()
            }
        }
        await fulfillment(of: [update], timeout: 1)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("done"))
    }

    func testProgressClassifiesReasoningAndBlockedToolsWithoutExposingPayloads() throws {
        let thought = Data(#"{"type":"reasoning","part":{"id":"r1","text":"Checking sources."}}"#.utf8)
        XCTAssertEqual(NotebookProviderProgress.decode(thought)?.kind, .reasoning)
        for line in [
            #"{"type":"tool_use","part":{"id":"t1","tool":"read","state":{"input":{"token":"secret"},"output":"secret"}}}"#,
            #"{"type":"item.started","item":{"id":"t1","type":"command_execution","command":"echo secret"}}"#
        ] {
            let event = try XCTUnwrap(NotebookProviderProgress.decode(Data(line.utf8)))
            XCTAssertEqual(event.kind, .tool)
            XCTAssertTrue(event.failed)
            XCTAssertNil(event.detail)
            XCTAssertFalse(event.title.contains("secret"))
        }
        let legacy = try JSONDecoder().decode(NotebookActivity.self, from: Data(#"{"id":"old","title":"Pensando…","date":0,"detail":"Saved reasoning"}"#.utf8))
        XCTAssertNil(legacy.kind)
        XCTAssertEqual(legacy.detail, "Saved reasoning")
    }

    func testOpenCodeSSEDeltasStayScopedAndSnapshotsDoNotDuplicateText() throws {
        var decoder = OpenCodeProgressDecoder(sessionID: "s1")
        func event(_ type: String, _ properties: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["type": type, "properties": properties])
        }
        XCTAssertNil(decoder.accept(try event("message.part.updated", ["part": ["sessionID": "other", "id": "r", "type": "reasoning", "text": "private"]])))
        XCTAssertEqual(decoder.accept(try event("message.part.updated", ["part": ["sessionID": "s1", "id": "r", "type": "reasoning", "text": "Check "]]))?.detail, "Check ")
        XCTAssertEqual(decoder.accept(try event("message.part.delta", ["sessionID": "s1", "partID": "r", "field": "text", "delta": "the math."]))?.detail, "Check the math.")
        XCTAssertEqual(decoder.accept(try event("message.part.updated", ["part": ["sessionID": "s1", "id": "r", "type": "reasoning", "text": "Check the math."]]))?.detail, "Check the math.")
        XCTAssertNil(decoder.accept(try event("message.part.delta", ["sessionID": "s1", "partID": "response", "field": "text", "delta": "private JSON"])))
        XCTAssertFalse(decoder.finished)
        _ = decoder.accept(try event("session.status", ["sessionID": "s1", "status": ["type": "idle"]]))
        XCTAssertTrue(decoder.finished)
    }

    func testOpenCodeHTTPReplyStillRejectsToolsAndPaidResponses() throws {
        func reply(cost: Double, parts: [[String: Any]]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["info": ["role": "assistant", "cost": cost], "parts": parts])
        }
        let parts: [[String: Any]] = [["type": "text", "text": "done"], ["type": "step-finish", "cost": 0, "reason": "stop"]]
        XCTAssertEqual(try OpenRouterHarness.decodeTextEvents(OpenCodeStreamingSession.completeEvents(reply(cost: 0, parts: parts))), "done")
        XCTAssertThrowsError(try OpenCodeStreamingSession.completeEvents(reply(cost: 1, parts: parts)))
        XCTAssertThrowsError(try OpenRouterHarness.decodeTextEvents(OpenCodeStreamingSession.completeEvents(reply(cost: 0, parts: [["type": "tool", "tool": "read"]] + parts))))
    }

    func testLiveOpenRouterReasoningArrivesInMultipleChunksBeforeCompletion() async throws {
        guard ProcessInfo.processInfo.environment["NOTES_LIVE_REASONING_TEST"] == "1" else { throw XCTSkip("Live OpenRouter test is opt-in.") }
        let (workspace, _) = try environment()
        let harness = OpenRouterHarness(store: LocalMediaStore(workspace: workspace), notebookEditing: true, allowRetention: true)
        let probe = ReasoningChunkProbe()
        let reply = try await harness.generateNotebook("Determine whether 10403 is prime and explain in one sentence. Do not read or edit files. Return JSON with reply, readFiles: [], edits: [].") { await probe.record($0) }
        let lengths = await probe.evidence()
        print("LIVE_REASONING_CHUNKS count=\(lengths.count) lengths=\(lengths.prefix(8))")
        XCTAssertGreaterThan(lengths.count, 1, "Reasoning must grow before step-finish, rather than arrive as one final block.")
        XCTAssertTrue(reply.contains("reply"))
        XCTAssertNoThrow(try NotebookAssistantProtocol.decode(reply))
    }

    func testCodexReasoningDeltasSeparateSummaryPartsAndRejectForeignTurns() throws {
        var decoder = CodexNotebookProgressDecoder(threadID: "thread")
        _ = try decoder.accept("turn/started", ["threadId": "thread", "turn": ["id": "turn"]])
        func delta(_ text: String, index: Int = 0, turn: String = "turn") -> [String: Any] {
            ["threadId": "thread", "turnId": turn, "itemId": "r1", "summaryIndex": index, "delta": text]
        }
        XCTAssertEqual(try decoder.accept("item/reasoning/summaryTextDelta", delta("Check "))?.detail, "Check ")
        XCTAssertEqual(try decoder.accept("item/reasoning/summaryTextDelta", delta("sources."))?.detail, "Check sources.")
        // A new summary section is a thought of its own.
        let next = try decoder.accept("item/reasoning/summaryTextDelta", delta("Next step.", index: 1))
        XCTAssertEqual(next?.detail, "Next step.")
        XCTAssertNotEqual(next?.id, try decoder.accept("item/reasoning/summaryTextDelta", delta("", index: 0))?.id)
        XCTAssertNil(try decoder.accept("item/reasoning/summaryTextDelta", delta("foreign", turn: "other")))
        XCTAssertThrowsError(try decoder.accept("item/started", ["threadId": "thread", "turnId": "turn", "item": ["type": "commandExecution"]]))
        XCTAssertThrowsError(try decoder.accept("turn/completed", ["threadId": "thread", "turn": ["id": "turn", "status": "failed"]]))
        XCTAssertFalse(decoder.finished)
    }

    func testAntigravityThoughtChunksArriveWhilePromptIsStillRunning() async throws {
        let (workspace, root) = try environment()
        let configuration = try mockACP(root, reasoning: true)
        let probe = ReasoningChunkProbe()
        let prompt = String(decoding: try OpenRouterHarness.payload(batch(workspace)), as: UTF8.self)
        _ = try await AntigravityTextTransport(store: LocalMediaStore(workspace: workspace), configuration: configuration).generate(prompt, progress: { event in
            if event.kind == .reasoning, event.detail?.isEmpty == false {
                XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("acp-completed").path))
            }
            await probe.record(event)
        })
        let lengths = await probe.evidence()
        XCTAssertEqual(lengths.count, 2)
    }

    func testLiveCodexAppServerStreamsReasoningBeforeTurnCompletion() async throws {
        guard ProcessInfo.processInfo.environment["NOTES_LIVE_CODEX_REASONING_TEST"] == "1" else { throw XCTSkip("Live Codex test is opt-in.") }
        let (workspace, _) = try environment()
        let configuration = AIProviderConfiguration(provider: .codexCLI, executablePath: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex", homePath: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path)
        let probe = ReasoningChunkProbe()
        let reply = try await CodexNotebookStreamingTransport(store: LocalMediaStore(workspace: workspace), configuration: configuration).generate("Determine whether 10403 is prime. Explain in one short sentence. Do not read or edit documents.", language: "en", images: []) { await probe.record($0) }
        let lengths = await probe.evidence()
        print("LIVE_CODEX_REASONING_CHUNKS count=\(lengths.count) lengths=\(lengths.prefix(8))")
        XCTAssertGreaterThan(lengths.count, 1)
        XCTAssertTrue(reply.contains("reply"))
    }

    func testLiveAntigravityACPStreamsThoughtChunksBeforeCompletion() async throws {
        guard ProcessInfo.processInfo.environment["NOTES_LIVE_ANTIGRAVITY_REASONING_TEST"] == "1" else { throw XCTSkip("Live Antigravity test is opt-in.") }
        let (workspace, _) = try environment()
        let settings = try JSONDecoder().decode(AIProviderSettings.self, from: Data(contentsOf: URL(fileURLWithPath: "/Users/biel/Documents/notes/session-storage/ai-provider-settings.json")))
        let probe = ReasoningChunkProbe()
        let reply = try await AntigravityTextTransport(store: LocalMediaStore(workspace: workspace), configuration: settings.antigravity).generate("Determine whether 10403 is prime. Explain in one sentence. Do not read files, edit files, use tools or run commands.", progress: { await probe.record($0) })
        let lengths = await probe.evidence()
        print("LIVE_ANTIGRAVITY_REASONING_CHUNKS count=\(lengths.count) lengths=\(lengths.prefix(8))")
        XCTAssertFalse(reply.isEmpty)
        guard !lengths.isEmpty else { throw XCTSkip("Configured Antigravity model completed successfully but published no thought chunks.") }
        XCTAssertGreaterThan(lengths.count, 1)
    }

    func testGenerationDeadlineAndExplicitCancellation() throws {
        XCTAssertEqual(ProviderRequestLimits.generation, 600)
        XCTAssertEqual(ProviderRequestLimits.diagnostic, 90)
        let cancelled = NotesProcess()
        cancelled.cancel()
        XCTAssertThrowsError(try cancelled.run()) { XCTAssertTrue($0 is CancellationError) }
    }

    func testProcessDeadlineStopsHelperAndReportsTimeoutSeparately() throws {
        let command = NotesProcess(timeoutInterval: 0.05)
        command.process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        command.process.arguments = ["5"]
        let start = Date()
        XCTAssertThrowsError(try command.run()) { error in
            XCTAssertTrue(error.localizedDescription.contains("agotó el tiempo"))
            XCTAssertFalse(error is CancellationError)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        XCTAssertFalse(command.process.isRunning)
    }

    private func environment() throws -> (SafeWorkspace, URL) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".test-workspaces/Provider-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("copied-course"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let workspace = try SafeWorkspace(root: root, originalRoot: root.appendingPathComponent("original"))
        try workspace.createNote("Test.md", text: "# Inventado\n\nTres pasos.\n")
        return (workspace, root)
    }

    private func batch(_ workspace: SafeWorkspace) throws -> AIBatch {
        var media = MediaJob(notebookID: "invented", subject: "Invented", note: "Test.md", sourceName: "Invented")
        media.transcript = [.init(id: "s1", start: 0, end: 10, text: "Son dos pasos, no tres.")]
        return try AIOutbox(workspace: workspace).enqueue(media: media, selected: media.transcript)
    }

    func testProvidersDefaultToEnabledAndPersistExplicitOptOuts() throws {
        let (workspace, _) = try environment()
        var settings = AIProviderSettings()
        XCTAssertEqual(settings.selectedProvider, .openCode)
        XCTAssertTrue(settings.openCode.accountSendingAllowed)
        XCTAssertTrue(settings.codexCLI.accountSendingAllowed)
        XCTAssertTrue(settings.antigravity.accountSendingAllowed)
        settings.openCode.accountSendingAllowed = false
        XCTAssertThrowsError(try settings.openCode.validateSending())
        settings.selectedProvider = .codexCLI
        settings.codexCLI.accountSendingAllowed = false
        XCTAssertThrowsError(try settings.selected.validateSending())
        settings.codexCLI.accountSendingAllowed = true
        settings.codexCLI.model = "example-model"
        try settings.save(in: workspace)
        let restored = try AIProviderSettings.load(in: workspace)
        XCTAssertEqual(restored, settings)
        XCTAssertFalse(restored.openCode.accountSendingAllowed)
        XCTAssertNoThrow(try restored.selected.validateSending())
        let data = String(decoding: try workspace.readStorage("ai-provider-settings.json"), as: UTF8.self)
        XCTAssertFalse(data.contains("apiKey"))
        XCTAssertFalse(data.contains("access_token"))
    }

    func testInvalidModelsPathsAndMismatchedProviderAreRejected() throws {
        let (workspace, _) = try environment()
        var settings = AIProviderSettings()
        settings.openCode.model = "openrouter/paid"
        XCTAssertThrowsError(try settings.save(in: workspace))
        settings = AIProviderSettings()
        settings.selectedProvider = .codexCLI
        settings.codexCLI.model = "model --yolo"
        XCTAssertThrowsError(try settings.save(in: workspace))
        settings.codexCLI.model = "default"
        settings.codexCLI.executablePath = "codex"
        XCTAssertThrowsError(try settings.save(in: workspace))
        settings.codexCLI.provider = .openCode
        XCTAssertThrowsError(try settings.save(in: workspace))
    }

    func testQueuedBatchKeepsProviderSnapshotAndLegacyBatchesDecode() throws {
        let (workspace, _) = try environment()
        var pending = try batch(workspace)
        pending.providerConfiguration = .init(provider: .codexCLI, executablePath: "/test/codex", model: "example-model", accountSendingAllowed: true)
        pending.model = "example-model"
        let outbox = try AIOutbox(workspace: workspace)
        try outbox.replace(pending)
        XCTAssertEqual(try AIOutbox(workspace: workspace).batches.first?.model, "example-model")
        let encoded = try JSONEncoder().encode(pending)
        XCTAssertEqual(try JSONDecoder().decode(AIBatch.self, from: encoded).providerConfiguration, pending.providerConfiguration)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "providerConfiguration")
        object["model"] = OpenRouterHarness.model
        XCTAssertNil(try JSONDecoder().decode(AIBatch.self, from: JSONSerialization.data(withJSONObject: object)).providerConfiguration)
    }

    func testCodexArgumentsDisableToolsHooksAndAmbientInstructions() throws {
        let configuration = AIProviderConfiguration(provider: .codexCLI, executablePath: "/test/codex")
        let arguments = try NotesProviderTransport.codexArguments(configuration, schema: URL(fileURLWithPath: "/tmp/schema.json"))
        for required in ["--ephemeral", "--ignore-user-config", "--ignore-rules", "read-only", "shell_tool", "hooks", "multi_agent", "apps", "browser_use", "computer_use", "mcp_servers={}", "project_doc_max_bytes=0", "web_search=\"disabled\""] {
            XCTAssertTrue(arguments.contains(required), required)
        }
        XCTAssertFalse(arguments.contains("--yolo"))
        XCTAssertFalse(arguments.contains("--model"))
    }

    func testModelCapabilitiesComeFromCatalogAndLegacySettingsStayManual() throws {
        let models = try ProviderModelCatalog.codexPage(["data": [
            ["model": "fast-model", "serviceTiers": [["id": "priority", "name": "Fast"]], "defaultReasoningEffort": "medium"],
            ["model": "slow-model"],
            ["model": "legacy-fast", "additionalSpeedTiers": ["fast"]]
        ]])
        XCTAssertEqual(models.map { $0.supportsFastMode == true }, [true, false, true])
        XCTAssertEqual(models.first?.defaultReasoningEffort, "medium")
        var settings = AIProviderSettings()
        settings.editAutonomy = .edits
        XCTAssertEqual(try JSONDecoder().decode(AIProviderSettings.self, from: JSONEncoder().encode(settings)).editAutonomy, .edits)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        legacy.removeValue(forKey: "editAutonomy")
        XCTAssertNil(try JSONDecoder().decode(AIProviderSettings.self, from: JSONSerialization.data(withJSONObject: legacy)).editAutonomy)
        XCTAssertFalse(AIEditAutonomy.edits.allows(.uncertain))
        XCTAssertFalse(AIEditAutonomy.additions.allows(.retract))
        XCTAssertTrue(AIEditAutonomy.edits.allows(.retract))
    }

    func testConnectionProbeIsTinyAndRejectsUnexpectedReplies() throws {
        XCTAssertLessThan(ProviderConnectionTest.prompt.utf8.count, 64)
        XCTAssertNoThrow(try ProviderConnectionTest.validateReply(#"{"ok":true}"#))
        for reply in [#"{"ok":false}"#, #"{"ok":1}"#, #"{"ok":true,"extra":"data"}"#, "", "OK"] {
            XCTAssertThrowsError(try ProviderConnectionTest.validateReply(reply))
        }
        XCTAssertThrowsError(try NotesProviderTransport.decodeCodexText(Data("{\"type\":\"turn.completed\"}\n".utf8)))
    }

    func testCodexFastModePersistsAndLeavesLegacySettingsCompatible() throws {
        var configuration = AIProviderConfiguration(provider: .codexCLI, executablePath: "/test/codex", model: "gpt-6-luna")
        let schema = URL(fileURLWithPath: "/tmp/schema.json")
        XCTAssertFalse(try NotesProviderTransport.codexArguments(configuration, schema: schema).contains("service_tier=\"fast\""))
        configuration.fastMode = true
        let restored = try JSONDecoder().decode(AIProviderConfiguration.self, from: JSONEncoder().encode(configuration))
        XCTAssertTrue(try NotesProviderTransport.codexArguments(restored, schema: schema).contains("service_tier=\"fast\""))
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)) as? [String: Any])
        legacy.removeValue(forKey: "fastMode")
        XCTAssertNil(try JSONDecoder().decode(AIProviderConfiguration.self, from: JSONSerialization.data(withJSONObject: legacy)).fastMode)
    }

    func testCodexCompletionRejectsToolsErrorsAndPartialResponses() throws {
        let (workspace, _) = try environment()
        let pending = try batch(workspace)
        let response: [String: Any] = ["version": 1, "batch_id": pending.id, "decisions": [["source_ids": ["s1"], "action": "correct", "text": "Dos pasos.", "reason": "Corrección inventada.", "target_quote": "Tres pasos."]]]
        let text = String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self)
        let event: [String: Any] = ["type": "item.completed", "item": ["type": "agent_message", "text": text]]
        let line = String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self)
        let completed = Data((line + "\n{\"type\":\"turn.completed\"}\n").utf8)
        let result = try NotesProviderTransport.decodeCodexEvents(completed, for: pending)
        XCTAssertEqual(result.stage, .ready)
        XCTAssertNil(result.reportedCost)
        XCTAssertEqual(result.decisions.first?.action, .correct)
        XCTAssertThrowsError(try NotesProviderTransport.decodeCodexEvents(Data(line.utf8), for: pending))
        for type in ["command_execution", "file_change", "mcp_tool_call", "web_search"] {
            let tool = "{\"type\":\"item.started\",\"item\":{\"type\":\"\(type)\"}}\n"
            XCTAssertThrowsError(try NotesProviderTransport.decodeCodexEvents(Data(tool.utf8) + completed, for: pending))
        }
        XCTAssertThrowsError(try NotesProviderTransport.decodeCodexEvents(Data("{\"type\":\"turn.failed\"}\n".utf8) + completed, for: pending))
        XCTAssertEqual(try workspace.readNote("Test.md"), "# Inventado\n\nTres pasos.\n")
    }

    func testModelCatalogParsingAndPreferencesPersistence() throws {
        let source = AIProviderModel(id: "gpt-6-sol", name: "GPT-6-Sol", reasoning: ["low", "medium", "high", "xhigh", "max", "ultra"])
        let expanded = ProviderModelCatalog.codexCatalog([source])
        XCTAssertEqual(expanded.first(where: { $0.id == "gpt-6.1-sol" })?.reasoning, source.reasoning)
        XCTAssertEqual(ProviderModelCatalog.codexCatalog(expanded).filter { $0.id == "gpt-6.1-sol" }.count, 1)
        let existing = AIProviderModel(id: "gpt-6.1-sol", name: "GPT-6.1-Sol", reasoning: ["low"])
        XCTAssertEqual(ProviderModelCatalog.codexCatalog([source, existing]).last?.reasoning, source.reasoning)
        for effort in source.reasoning {
            var configuration = AIProviderConfiguration(provider: .codexCLI, executablePath: "/test/codex", model: "gpt-6.1-sol")
            configuration.reasoningEffort = effort
            XCTAssertNoThrow(try configuration.validate())
            let restored = try JSONDecoder().decode(AIProviderConfiguration.self, from: JSONEncoder().encode(configuration))
            XCTAssertEqual(restored, configuration)
            let arguments = try NotesProviderTransport.codexArguments(restored, schema: URL(fileURLWithPath: "/tmp/schema.json"))
            XCTAssertTrue(arguments.contains("gpt-6.1-sol"))
            XCTAssertTrue(arguments.contains("model_reasoning_effort=\"\(effort)\""))
        }
        let models = try ProviderModelCatalog.codexPage(["data": [["id": "example", "model": "example-model", "displayName": "Example", "isDefault": true, "supportedReasoningEfforts": [["reasoningEffort": "low"]]], ["id": "hidden", "hidden": true]]])
        XCTAssertEqual(models.map(\.id), ["example-model"])
        XCTAssertEqual(models.first?.reasoning, ["low"])
        let gravity = try ProviderModelCatalog.antigravitySession(["configOptions": [["id": "model", "currentValue": "model-a", "options": [["group": "Group", "options": [["value": "model-a", "name": "Model A"]]]]]]])
        XCTAssertEqual(gravity.first?.name, "Model A")
        XCTAssertEqual(gravity.first?.isDefault, true)
        XCTAssertThrowsError(try ProviderModelCatalog.codexPage(["data": [["model": "unsafe --flag"]]]))
        let (workspace, _) = try environment()
        var settings = AIProviderSettings()
        var preferences = AIProviderModelPreferences()
        preferences.favorites = ["model-a"]; preferences.hidden = ["model-b"]; preferences.order = ["model-b", "model-a"]
        settings.modelPreferences = [NotesAIProvider.antigravity.rawValue: preferences]
        try settings.save(in: workspace)
        XCTAssertEqual(try AIProviderSettings.load(in: workspace).modelPreferences, settings.modelPreferences)
    }

    func testInstalledProviderModelCatalogs() async throws {
        guard ProcessInfo.processInfo.environment["NOTES_MODEL_PROBES"] == "1" else { throw XCTSkip("Set NOTES_MODEL_PROBES=1 to query model catalogs through existing accounts without prompts.") }
        let (workspace, _) = try environment()
        let transport = NotesProviderTransport(store: LocalMediaStore(workspace: workspace))
        let settings = AIProviderSettings()
        for provider in NotesAIProvider.allCases {
            let models = try await transport.models(settings.configuration(for: provider))
            XCTAssertFalse(models.isEmpty)
            XCTAssertEqual(Set(models.map(\.id)).count, models.count)
            print("Model catalog \(provider.rawValue): \(models.map(\.name).joined(separator: ", "))")
            if provider == .codexCLI {
                XCTAssertEqual(models.first(where: { $0.id == "gpt-6.1-sol" })?.reasoning, models.first(where: { $0.id == "gpt-6-sol" })?.reasoning)
                print("GPT-6.1-Sol reasoning: \(models.first(where: { $0.id == "gpt-6.1-sol" })?.reasoning ?? [])")
            }
        }
    }

    func testInstalledProviderReadOnlyDiagnostics() async throws {
        guard ProcessInfo.processInfo.environment["NOTES_PROVIDER_PROBES"] == "1" else { throw XCTSkip("Set NOTES_PROVIDER_PROBES=1 for installed-runtime diagnostics without login or prompts.") }
        let (workspace, _) = try environment()
        let transport = NotesProviderTransport(store: LocalMediaStore(workspace: workspace))
        let settings = AIProviderSettings()
        for provider in NotesAIProvider.allCases {
            let diagnostic = try await transport.diagnose(settings.configuration(for: provider))
            XCTAssertFalse(diagnostic.message.isEmpty)
            print("Provider diagnostic: \(provider.rawValue): \(diagnostic.message)")
        }
        XCTAssertEqual(try workspace.readNote("Test.md"), "# Inventado\n\nTres pasos.\n")
    }

    func testAntigravityCancellationClosesUnresponsiveHelper() async throws {
        let (workspace, root) = try environment()
        let configuration = try mockACP(root, unresponsive: true)
        let transport = NotesProviderTransport(store: LocalMediaStore(workspace: workspace))
        let operation = Task { try await transport.diagnose(configuration) }
        try await Task.sleep(for: .milliseconds(200))
        operation.cancel()
        do { _ = try await operation.value; XCTFail("Cancelled diagnostic succeeded") }
        catch {}
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".provider-helper-") })
    }

    private func mockACP(_ root: URL, toolRequest: Bool = false, unresponsive: Bool = false, images: Bool = false, reasoning: Bool = false) throws -> AIProviderConfiguration {
        let script = root.appendingPathComponent("mock-acp.py")
        let content = """
        #!/usr/bin/python3
        import sys,json,re,uuid,time,signal
        if \(unresponsive ? "True" : "False"):
            signal.signal(signal.SIGTERM,signal.SIG_IGN)
            time.sleep(60)
        session=str(uuid.uuid4())
        def emit(value):
            print(json.dumps(value),flush=True)
        for line in sys.stdin:
            request=json.loads(line)
            method=request.get('method')
            result={}
            if method=='initialize':
                assert request['params']['clientCapabilities']['terminal'] is False
                assert request['params']['clientCapabilities']['fs']['readTextFile'] is False
                result={'protocolVersion':2,'agentInfo':{'name':'antigravity-acp','version':'mock'},'agentCapabilities':{'promptCapabilities':{'image':\(images ? "True" : "False")}}}
            if method=='session/new':
                assert request['params']['mcpServers']==[]
                result={'sessionId':session}
            if method=='session/prompt':
                if \(reasoning ? "True" : "False"):
                    for chunk in ['Checking ', 'sources as they arrive.']:
                        emit({'jsonrpc':'2.0','method':'session/update','params':{'sessionId':session,'update':{'sessionUpdate':'agent_thought_chunk','content':{'type':'text','text':chunk}}}})
                        time.sleep(0.2)
                    open('\(root.appendingPathComponent("acp-completed").path)','w').write('done')
                if \(toolRequest ? "True" : "False"):
                    emit({'jsonrpc':'2.0','id':900,'method':'fs/read_text_file','params':{'path':'/private'}})
                    continue
                if \(images ? "True" : "False"):
                    image=request['params']['prompt'][1]
                    assert image['type']=='image' and image['mimeType']=='image/png' and image['data']=='aW1hZ2U='
                    emit({'jsonrpc':'2.0','method':'session/update','params':{'sessionId':session,'update':{'sessionUpdate':'agent_message_chunk','content':{'type':'text','text':'Image received'}}}})
                    emit({'jsonrpc':'2.0','id':request['id'],'result':{'stopReason':'end_turn'}})
                    continue
                payload=json.loads(request['params']['prompt'][0]['text'].splitlines()[-1])
                text=json.dumps({'version':1,'batch_id':payload['batch_id'],'decisions':[{'source_ids':['s1'],'action':'correct','text':'Dos pasos.','reason':'Inventado','target_quote':'Tres pasos.'}]})
                emit({'jsonrpc':'2.0','method':'session/update','params':{'sessionId':session,'update':{'sessionUpdate':'agent_message_chunk','content':{'type':'text','text':text}}}})
                result={'stopReason':'end_turn'}
            emit({'jsonrpc':'2.0','id':request['id'],'result':result})
        """
        try content.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let profile = root.appendingPathComponent("profile")
        try FileManager.default.createDirectory(at: profile.appendingPathComponent("antigravity-acp"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: profile.appendingPathComponent("antigravity-acp/acp_token.json"))
        return .init(provider: .antigravity, executablePath: script.path, homePath: profile.path, harnessPath: script.path, accountSendingAllowed: true)
    }

    func testAntigravityImagePayloadAndCapabilityGuard() async throws {
        let (workspace, root) = try environment()
        let image = NotebookInputImage(name: "fixture.png", data: Data("image".utf8))
        let configuration = try mockACP(root, images: true)
        let transport = AntigravityTextTransport(store: LocalMediaStore(workspace: workspace), configuration: configuration)
        let reply = try await transport.generate("Inspect fixture", images: [image])
        XCTAssertEqual(reply, "Image received")
        let unsupported = try mockACP(root)
        do {
            _ = try await AntigravityTextTransport(store: LocalMediaStore(workspace: workspace), configuration: unsupported).generate("Inspect fixture", images: [image])
            XCTFail("Must reject missing image capability")
        } catch { XCTAssertTrue(error.localizedDescription.contains("image support")) }
    }

    func testAntigravityACPHandshakeTextOnlyCompletionAndNoNoteMutation() async throws {
        let (workspace, root) = try environment()
        let configuration = try mockACP(root)
        let transport = NotesProviderTransport(store: LocalMediaStore(workspace: workspace))
        let diagnostic = try await transport.diagnose(configuration)
        XCTAssertTrue(diagnostic.message.contains("protocolo verificado"))
        let result = try await transport.send(batch(workspace), configuration: configuration)
        XCTAssertEqual(result.stage, .ready)
        XCTAssertEqual(result.decisions.first?.text, "Dos pasos.")
        XCTAssertNil(result.reportedCost)
        XCTAssertEqual(try workspace.readNote("Test.md"), "# Inventado\n\nTres pasos.\n")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".provider-helper-") })
    }

    func testAntigravityToolRequestsAndGlobalHooksAreRejected() async throws {
        let (workspace, root) = try environment()
        let configuration = try mockACP(root, toolRequest: true)
        let transport = NotesProviderTransport(store: LocalMediaStore(workspace: workspace))
        do { _ = try await transport.send(batch(workspace), configuration: configuration); XCTFail("Tool request accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("herramientas")) }
        let folder = URL(fileURLWithPath: configuration.homePath).appendingPathComponent("config")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"hooks":{"SessionStart":["unsafe"]}}"#.utf8).write(to: folder.appendingPathComponent("hooks.json"))
        XCTAssertThrowsError(try AntigravityTextTransport.validateProfile(configuration.homePath))
        try Data(#"{"hooks":{}}"#.utf8).write(to: folder.appendingPathComponent("hooks.json"))
        XCTAssertNoThrow(try AntigravityTextTransport.validateProfile(configuration.homePath))
        try Data(#"{"mcpServers":{"outside":{}}}"#.utf8).write(to: folder.appendingPathComponent("mcp_config.json"))
        XCTAssertThrowsError(try AntigravityTextTransport.validateProfile(configuration.homePath))
    }
}
private actor ReasoningChunkProbe {
    var lengths: [Int] = []
    var finished = false
    func record(_ event: NotebookProviderProgress) {
        if event.id == "provider-finished" { finished = true }
        if !finished, event.kind == .reasoning, let text = event.detail, !text.isEmpty,
           text.count > (lengths.last ?? 0) { lengths.append(text.count) }
    }
    func evidence() -> [Int] { lengths }
}
