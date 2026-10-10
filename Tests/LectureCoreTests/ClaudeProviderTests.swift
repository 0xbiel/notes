import XCTest
@testable import LectureCore

final class ClaudeProviderTests: XCTestCase {
    private func environment() throws -> (SafeWorkspace, URL) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".test-workspaces/Claude-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("copied-course"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let workspace = try SafeWorkspace(root: root, originalRoot: root.appendingPathComponent("original"))
        try workspace.createNote("Test.md", text: "# Inventado\n\nTres pasos.\n")
        return (workspace, root)
    }

    /// A stand-in for `claude -p` that checks the isolation arguments and
    /// environment it receives, then replays a stream-json session.
    private func mockClaude(_ root: URL, mode: String = "ok") throws -> AIProviderConfiguration {
        let script = root.appendingPathComponent("mock-claude.py")
        let content = """
        #!/usr/bin/python3
        import sys,json,os
        args=sys.argv[1:]
        if args==['--version']:
            print('2.1.296 (Claude Code)'); sys.exit(0)
        if args==['--help']:
            print(' '.join(\(ClaudeTextTransport.requiredFlags))); sys.exit(0)
        def emit(value): print(json.dumps(value),flush=True)
        def value(flag): return args[args.index(flag)+1]
        assert args[0]=='-p' and '--safe-mode' in args and '--strict-mcp-config' in args and '--no-session-persistence' in args
        assert value('--permission-mode')=='dontAsk' and value('--output-format')=='stream-json'
        assert json.loads(value('--settings'))['disableAllHooks'] is True
        assert os.environ.get('CLAUDE_CONFIG_DIR')=='\(root.appendingPathComponent("claude-home").path)'
        assert os.environ.get('MOCK_MODE')=='\(mode)' and 'CLAUDECODE' not in os.environ
        assert os.getcwd()!='\(root.path)' and os.listdir('.')==['input.txt']
        mode=os.environ['MOCK_MODE']
        web=value('--tools')=='WebSearch'
        emit({'type':'system','subtype':'init','tools':['StructuredOutput']+(['WebSearch'] if web else [])+(['Bash'] if mode=='ambient' else []),'mcp_servers':[]})
        text=sys.stdin.read()
        if mode=='error':
            emit({'type':'result','subtype':'success','is_error':True,'result':'Not logged in · Please run /login'}); sys.exit(1)
        emit({'type':'assistant','message':{'content':[{'type':'thinking','thinking':'Comparing the transcript with the note.'}]}})
        if mode=='tool':
            emit({'type':'assistant','message':{'content':[{'type':'tool_use','id':'t1','name':'Bash','input':{'command':'ls'}}]}})
        if web:
            emit({'type':'assistant','message':{'content':[{'type':'tool_use','id':'w1','name':'WebSearch','input':{'query':'invented query'}}]}})
        if '--input-format' in args:
            message=json.loads(text)['message']['content']
            assert message[1]['source']=={'type':'base64','media_type':'image/png','data':'aW1hZ2U='}
            output={'reply':'Image received','readFiles':[],'edits':[],'webActions':[]}
        elif json.loads(value('--json-schema'))['required']==['ok']:
            output={'ok':True}
        elif 'batch_id' in json.loads(value('--json-schema'))['required']:
            payload=json.loads(text.splitlines()[-1])
            output={'version':1,'batch_id':payload['batch_id'],'decisions':[{'source_ids':['s1'],'action':'correct','text':'Dos pasos.','reason':'Inventado','target_quote':'Tres pasos.'}]}
        else:
            output={'reply':'Hecho','readFiles':[],'edits':[],'webActions':[]}
        emit({'type':'assistant','message':{'content':[{'type':'tool_use','id':'s1','name':'StructuredOutput','input':output}]}})
        emit({'type':'result','subtype':'success','is_error':False,'result':json.dumps(output),'structured_output':output})
        """
        try content.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        var configuration = AIProviderConfiguration(provider: .claudeCode, executablePath: script.path, model: "claude-opus-4-7", homePath: root.appendingPathComponent("claude-home").path)
        configuration.environment = [.init(name: "MOCK_MODE", value: mode)]
        return configuration
    }

    private actor Progress {
        var events: [NotebookProviderProgress] = []
        func record(_ event: NotebookProviderProgress) { events.append(event) }
    }

    func testClaudeArgumentsIsolateTheSessionAndApplyTheSelection() throws {
        var configuration = AIProviderConfiguration(provider: .claudeCode, executablePath: "/test/claude", model: "claude-opus-4-7")
        configuration.reasoningEffort = "xhigh"; configuration.fastMode = true
        configuration.autoCompactWindow = "300000"; configuration.launchArguments = "--fallback-model sonnet"
        let arguments = try ClaudeTextTransport.arguments(configuration, schema: ["type": "object"], instructions: "Return JSON.")
        for required in ["-p", "--safe-mode", "--strict-mcp-config", "--disable-slash-commands", "--no-session-persistence", "dontAsk", "stream-json"] {
            XCTAssertTrue(arguments.contains(required), required)
        }
        func value(_ flag: String) -> String? { arguments.firstIndex(of: flag).map { arguments[$0 + 1] } }
        XCTAssertEqual(value("--tools"), "")
        XCTAssertEqual(value("--model"), "claude-opus-4-7")
        // Opus 4.7 spells its top level differently in the CLI.
        XCTAssertEqual(value("--effort"), "max")
        XCTAssertEqual(value("--autocompact"), "300000")
        XCTAssertEqual(value("--system-prompt"), "Return JSON.")
        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(value("--settings")).utf8)) as? [String: Bool])
        XCTAssertEqual(settings, ["disableAllHooks": true, "fastMode": true])
        // Launch arguments precede the enforced options, which therefore prevail.
        XCTAssertLessThan(try XCTUnwrap(arguments.firstIndex(of: "--fallback-model")), try XCTUnwrap(arguments.firstIndex(of: "--safe-mode")))
        XCTAssertFalse(arguments.contains("--input-format"))

        var plain = AIProviderConfiguration(provider: .claudeCode, executablePath: "/test/claude")
        let web = try ClaudeTextTransport.arguments(plain, schema: [:], instructions: "", webSearch: true, imageInput: true)
        XCTAssertFalse(web.contains("--model"))
        XCTAssertFalse(web.contains("--effort"))
        XCTAssertEqual(web.firstIndex(of: "--tools").map { web[$0 + 1] }, "WebSearch")
        XCTAssertTrue(web.contains("--input-format"))
        plain.model = "claude-opus-4-6"
        XCTAssertEqual(ClaudeModel.selection(plain).model, "claude-opus-4-6[1m]")
        plain.model = "openai/gpt-router-model"
        XCTAssertEqual(ClaudeModel.selection(plain).model, "openai/gpt-router-model")
    }

    func testClaudeStreamAcceptsStructuredOutputAndRejectsEverythingElse() throws {
        func line(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
        var decoder = ClaudeStreamDecoder()
        XCTAssertEqual(try decoder.accept(line(["type": "system", "subtype": "init", "tools": ["StructuredOutput"], "mcp_servers": []]))?.id, "provider-start")
        XCTAssertNil(try decoder.accept(Data("not json".utf8)))
        XCTAssertNil(try decoder.accept(line(["type": "rate_limit_event"])))
        let thought = try decoder.accept(line(["type": "assistant", "message": ["content": [["type": "thinking", "thinking": "Reading."]]]]))
        XCTAssertEqual(thought?.kind, .reasoning)
        XCTAssertEqual(thought?.detail, "Reading.")
        XCTAssertNil(decoder.output)
        _ = try decoder.accept(line(["type": "result", "subtype": "success", "is_error": false, "structured_output": ["ok": true]]))
        XCTAssertNoThrow(try ProviderConnectionTest.validateReply(try XCTUnwrap(decoder.output)))

        var ambient = ClaudeStreamDecoder()
        XCTAssertThrowsError(try ambient.accept(line(["type": "system", "subtype": "init", "tools": ["StructuredOutput", "Bash"], "mcp_servers": []])))
        XCTAssertThrowsError(try ambient.accept(line(["type": "system", "subtype": "init", "tools": ["StructuredOutput"], "mcp_servers": [["name": "files"]]])))
        // Web search is a tool only for requests that enabled it.
        let search: [String: Any] = ["type": "assistant", "message": ["content": [["type": "tool_use", "id": "w", "name": "WebSearch", "input": ["query": "invented"]]]]]
        XCTAssertThrowsError(try ambient.accept(line(search)))
        var web = ClaudeStreamDecoder(webSearch: true)
        XCTAssertEqual(try web.accept(line(search))?.detail, "invented")
        XCTAssertThrowsError(try web.accept(line(["type": "result", "subtype": "success", "is_error": true, "result": "Not logged in"]))) {
            XCTAssertTrue($0.localizedDescription.contains("Not logged in"))
        }
        XCTAssertThrowsError(try web.accept(line(["type": "result", "subtype": "error_max_turns", "is_error": false])))
    }

    func testClaudeCatalogFollowsTheInstalledVersion() {
        XCTAssertEqual(ClaudeModel.version(from: "2.1.296 (Claude Code)\n"), "2.1.296")
        XCTAssertNil(ClaudeModel.version(from: "command not found"))
        let current = ClaudeModel.catalog(version: "2.1.296")
        XCTAssertEqual(current.count, ClaudeModel.all.count)
        XCTAssertEqual(Set(current.map(\.id)).count, current.count)
        XCTAssertEqual(current.filter(\.isDefault).map(\.id), ["claude-fable-5-1"])
        XCTAssertEqual(current.first { $0.id == "claude-opus-5-5" }?.supportsFastMode, true)
        XCTAssertEqual(current.first { $0.id == "claude-sonnet-5-5" }?.defaultReasoningEffort, "high")
        // 2.1.280 runs Opus 5.5 but predates Sonnet 5.5 and Haiku 5.5.
        let older = ClaudeModel.catalog(version: "2.1.280").map(\.id)
        XCTAssertTrue(older.contains("claude-opus-5-5"))
        XCTAssertFalse(older.contains("claude-sonnet-5-5"))
        XCTAssertFalse(older.contains("claude-haiku-5-5"))
        XCTAssertFalse(ClaudeModel.catalog(version: "2.1.99").contains { $0.id == "claude-opus-4-7" })
        XCTAssertTrue(ClaudeModel.catalog(version: nil).contains { $0.id == "claude-haiku-4-5" })
        for model in current { XCTAssertNoThrow(try ProviderModelCatalog.validateID(model.id)) }
        for model in ClaudeModel.all { XCTAssertTrue(Set(model.effortMap.keys).isSubset(of: Set(model.efforts))) }
    }

    func testSettingsSavedBeforeClaudeExistedStillLoad() throws {
        let (workspace, _) = try environment()
        var settings = AIProviderSettings()
        settings.selectedProvider = .codexCLI
        settings.codexCLI.model = "example-model"
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        legacy.removeValue(forKey: "claudeCode")
        try workspace.writeStorage("ai-provider-settings.json", data: JSONSerialization.data(withJSONObject: legacy))
        var restored = try AIProviderSettings.load(in: workspace)
        XCTAssertEqual(restored.codexCLI.model, "example-model")
        XCTAssertEqual(restored.claudeCode.provider, .claudeCode)
        XCTAssertTrue(restored.claudeCode.accountSendingAllowed)
        XCTAssertEqual(restored.claudeCode.homePath, "")
        restored.selectedProvider = .claudeCode
        restored.claudeCode.displayName = "Claude Personal"
        restored.claudeCode.accentColor = "#3E63DD"
        restored.claudeCode.autoCompactWindow = "300000"
        try restored.save(in: workspace)
        let reopened = try AIProviderSettings.load(in: workspace)
        XCTAssertEqual(reopened.selected.name, "Claude Personal")
        XCTAssertEqual(reopened.claudeCode.autoCompactWindow, "300000")
        XCTAssertEqual(reopened[.claudeCode], reopened.claudeCode)
        XCTAssertEqual(AIProviderSettings().claudeCode.name, "Claude")
    }

    func testInstanceOptionsValidateTheirValues() throws {
        var claude = AIProviderConfiguration(provider: .claudeCode, executablePath: "/test/claude")
        XCTAssertNoThrow(try claude.validate())
        for window in ["99999", "1000001", "300k", "0300000"] {
            claude.autoCompactWindow = window
            XCTAssertThrowsError(try claude.validate(), window)
        }
        claude.autoCompactWindow = "1000000"
        XCTAssertNoThrow(try claude.validate())
        claude.accentColor = "blue"
        XCTAssertThrowsError(try claude.validate())
        claude.accentColor = nil
        claude.authMethod = AntigravityAuthMethod.apiKey.rawValue
        XCTAssertThrowsError(try claude.validate())

        var codex = AIProviderConfiguration(provider: .codexCLI, executablePath: "/test/codex", homePath: "/accounts/shared")
        codex.autoCompactWindow = "300000"
        XCTAssertThrowsError(try codex.validate())
        codex.autoCompactWindow = nil
        XCTAssertEqual(codex.accountHomePath, "/accounts/shared")
        codex.shadowHomePath = "relative/home"
        XCTAssertThrowsError(try codex.validate())
        codex.shadowHomePath = "/accounts/personal"
        XCTAssertNoThrow(try codex.validate())
        XCTAssertEqual(codex.accountHomePath, "/accounts/personal")
        XCTAssertEqual(try NotesProviderTransport.codexEnvironment(codex)["CODEX_HOME"], "/accounts/personal")
    }

    func testEnvironmentVariablesReachTheProcessAndKeepSecretsOutOfSettings() throws {
        var configuration = AIProviderConfiguration(provider: .claudeCode, executablePath: "/test/claude", homePath: "/accounts/router")
        configuration.environment = [.init(name: "ANTHROPIC_BASE_URL", value: "https://router.invalid/api"), .init(name: "ANTHROPIC_API_KEY"), .init(name: "ANTHROPIC_AUTH_TOKEN", sensitive: true), .init(name: "CLAUDE_CONFIG_DIR", value: "/elsewhere")]
        XCTAssertNoThrow(try configuration.validate())
        let (workspace, _) = try environment()
        var transport = ClaudeTextTransport(store: LocalMediaStore(workspace: workspace), configuration: configuration)
        transport.secret = { provider, name in
            XCTAssertEqual(provider, .claudeCode)
            return name == "env/ANTHROPIC_AUTH_TOKEN" ? "invented-token" : nil
        }
        let variables = try transport.environment()
        XCTAssertEqual(variables["ANTHROPIC_BASE_URL"], "https://router.invalid/api")
        // An explicitly empty value is passed through, as router setups require.
        XCTAssertEqual(variables["ANTHROPIC_API_KEY"], "")
        XCTAssertEqual(variables["ANTHROPIC_AUTH_TOKEN"], "invented-token")
        // The configured account directory prevails over an instance variable.
        XCTAssertEqual(variables["CLAUDE_CONFIG_DIR"], "/accounts/router")
        XCTAssertNil(variables["CLAUDECODE"])
        let stored = String(decoding: try JSONEncoder().encode(configuration), as: UTF8.self)
        XCTAssertFalse(stored.contains("invented-token"))
        transport.secret = { _, _ in nil }
        XCTAssertThrowsError(try transport.environment()) { XCTAssertTrue($0.localizedDescription.contains("ANTHROPIC_AUTH_TOKEN")) }

        for invalid in [[AIProviderEnvironmentVariable(name: "1BAD")], [.init(name: "HAS SPACE")], [.init(name: "A"), .init(name: "A")], [.init(name: "SECRET", value: "inline", sensitive: true)], [.init(name: "NUL", value: "a\0b")]] {
            XCTAssertThrowsError(try ProviderEnvironment.validate(invalid))
        }
    }

    func testLaunchArgumentsCannotReplaceManagedOptions() throws {
        XCTAssertEqual(try ProviderLaunchArguments.tokenize(#"--betas "a b" 'c d' e\ f  --flag="#), ["--betas", "a b", "c d", "e f", "--flag="])
        XCTAssertEqual(try ProviderLaunchArguments.tokenize("  "), [])
        XCTAssertThrowsError(try ProviderLaunchArguments.tokenize("--betas \"open"))
        var claude = AIProviderConfiguration(provider: .claudeCode, executablePath: "/test/claude")
        claude.launchArguments = "--fallback-model sonnet --debug api"
        XCTAssertEqual(try ProviderLaunchArguments.resolve(claude), ["--fallback-model", "sonnet", "--debug", "api"])
        for managed in ["--dangerously-skip-permissions", "--permission-mode bypassPermissions", "--tools Bash", "--mcp-config servers.json", "--add-dir /", "--model=opus", "--chrome", "--output-format text", "--system-prompt hi"] {
            claude.launchArguments = managed
            XCTAssertThrowsError(try claude.validate(), managed)
        }
        var codex = AIProviderConfiguration(provider: .codexCLI, executablePath: "/test/codex")
        codex.launchArguments = #"-c model_verbosity="low" --config=hide_agent_reasoning=true --disable some_feature --strict-config"#
        let resolved = try ProviderLaunchArguments.resolve(codex)
        XCTAssertEqual(resolved, ["--config", "model_verbosity=low", "--config", "hide_agent_reasoning=true", "--disable", "some_feature", "--strict-config"])
        let arguments = try NotesProviderTransport.codexArguments(codex, schema: URL(fileURLWithPath: "/tmp/schema.json"))
        XCTAssertEqual(Array(arguments[1...resolved.count]), resolved)
        XCTAssertLessThan(try XCTUnwrap(arguments.firstIndex(of: "--strict-config")), try XCTUnwrap(arguments.firstIndex(of: "--ephemeral")))
        for managed in ["--enable shell_tool", "--config approval_policy=\"on-request\"", "-c mcp_servers.files.command=\"x\"", "--config features.shell_tool=true", "--yolo", "--sandbox danger-full-access", "--config"] {
            codex.launchArguments = managed
            XCTAssertThrowsError(try codex.validate(), managed)
        }
    }

    func testAntigravitySignInMethodsNameTheirRequirements() throws {
        let (workspace, root) = try environment()
        var configuration = AIProviderConfiguration(provider: .antigravity, executablePath: "/test/agy", homePath: root.appendingPathComponent("profile").path, harnessPath: "/test/harness")
        func transport(key: String? = nil) -> AntigravityTextTransport {
            var value = AntigravityTextTransport(store: LocalMediaStore(workspace: workspace), configuration: configuration)
            value.secret = { _, name in name == ProviderSecrets.antigravityAPIKey ? key : nil }
            return value
        }
        XCTAssertEqual(configuration.antigravityAuth, .personal)
        XCTAssertNil(try transport().authIssue())
        configuration.authMethod = AntigravityAuthMethod.apiKey.rawValue
        XCTAssertNotNil(try transport().authIssue())
        XCTAssertNil(try transport(key: "invented-key").authIssue())
        configuration.authMethod = AntigravityAuthMethod.business.rawValue
        XCTAssertNotNil(try transport(key: "invented-key").authIssue())
        configuration.gcpProject = "invented-project"; configuration.gcpLocation = "us-central1"
        XCTAssertNil(try transport().authIssue())
        XCTAssertNoThrow(try configuration.validate())
        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: AntigravityTextTransport.profileSettings(configuration)) as? [String: [String: String]])
        XCTAssertEqual(settings, ["auth": ["type": "oauth-business"], "gcp": ["project": "invented-project", "location": "us-central1"]])
        configuration.authMethod = AntigravityAuthMethod.agentPlatform.rawValue
        XCTAssertNil(try transport().authIssue())
        configuration.gcpProject = nil
        XCTAssertNotNil(try transport().authIssue())
        XCTAssertNil(try transport(key: "invented-key").authIssue())
        configuration.gcpLocation = "us central"
        XCTAssertThrowsError(try configuration.validate())
        configuration.gcpLocation = nil; configuration.authMethod = "oauth-unknown"
        XCTAssertThrowsError(try configuration.validate())
    }

    func testMockClaudeCompletesBatchNotebookImageAndProbeRequests() async throws {
        let (workspace, root) = try environment()
        let store = LocalMediaStore(workspace: workspace)
        let configuration = try mockClaude(root)
        let transport = NotesProviderTransport(store: store)

        let diagnostic = try await transport.diagnose(configuration)
        XCTAssertEqual(diagnostic.version, "2.1.296")
        let models = try await transport.models(configuration)
        XCTAssertEqual(models.count, ClaudeModel.all.count)

        var media = MediaJob(notebookID: "invented", subject: "Invented", note: "Test.md", sourceName: "Invented")
        media.transcript = [.init(id: "s1", start: 0, end: 10, text: "Son dos pasos, no tres.")]
        let batch = try AIOutbox(workspace: workspace).enqueue(media: media, selected: media.transcript)
        let result = try await transport.send(batch, configuration: configuration)
        XCTAssertEqual(result.stage, .ready)
        XCTAssertEqual(result.decisions.first?.text, "Dos pasos.")
        XCTAssertNil(result.reportedCost)

        let progress = Progress()
        let request = NotebookTextRequest(notebook: Notebook(id: "invented", name: "Invented", rootPrefix: ""), profile: NotebookProfile(), messages: [NotebookMessage(role: "user", text: "Hola")], currentDocument: nil, texts: [:], language: "en")
        let reply = try await transport.sendNotebook(request, configuration: configuration, progress: { await progress.record($0) })
        XCTAssertEqual(reply.reply, "Hecho")
        let events = await progress.events
        XCTAssertEqual(events.first?.id, "provider-start")
        XCTAssertTrue(events.contains { $0.kind == .reasoning && $0.detail == "Comparing the transcript with the note." })
        // The request left web access on, so the native search is reported.
        XCTAssertTrue(events.contains { $0.kind == .tool && $0.detail == "invented query" })
        XCTAssertEqual(events.last?.id, "provider-finished")

        let image = NotebookInputImage(name: "fixture.png", data: Data("image".utf8))
        let described = try await transport.sendNotebook(request, configuration: configuration, images: [image])
        XCTAssertEqual(described.reply, "Image received")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".provider-helper-") })
        XCTAssertEqual(try workspace.readNote("Test.md"), "# Inventado\n\nTres pasos.\n")
    }

    func testMockClaudeRejectsToolsAmbientSessionsAndAccountErrors() async throws {
        let (workspace, root) = try environment()
        let store = LocalMediaStore(workspace: workspace)
        for (mode, expected) in [("tool", "Bash"), ("ambient", "MCP"), ("error", "Not logged in")] {
            let transport = ClaudeTextTransport(store: store, configuration: try mockClaude(root, mode: mode))
            do {
                _ = try await transport.generate("Hola", schema: NotebookAssistantProtocol.schema, instructions: "Return JSON.")
                XCTFail("Must reject \(mode)")
            } catch { XCTAssertTrue(error.localizedDescription.contains(expected), "\(mode): \(error.localizedDescription)") }
        }
        var disabled = try mockClaude(root)
        disabled.accountSendingAllowed = false
        do {
            _ = try await ClaudeTextTransport(store: store, configuration: disabled).generate("Hola", schema: [:], instructions: "")
            XCTFail("Must not send through a disabled provider")
        } catch {}
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".provider-helper-") })
    }

    func testLiveClaudeConnectionAndNotebookReply() async throws {
        guard ProcessInfo.processInfo.environment["NOTES_LIVE_CLAUDE_TEST"] == "1" else { throw XCTSkip("Set NOTES_LIVE_CLAUDE_TEST=1 to send two tiny invented prompts through the installed Claude Code account.") }
        var configuration = AIProviderSettings().claudeCode
        configuration.model = ProcessInfo.processInfo.environment["NOTES_CLAUDE_TEST_MODEL"] ?? "claude-haiku-5-5"
        configuration.reasoningEffort = "low"
        let probe = try await ProviderConnectionTest.run(configuration)
        XCTAssertEqual(probe.provider, .claudeCode)
        let (workspace, _) = try environment()
        var request = NotebookTextRequest(notebook: Notebook(id: "invented", name: "Invented", rootPrefix: ""), profile: NotebookProfile(), messages: [NotebookMessage(role: "user", text: "Reply with the single word ready. Do not read or edit documents.")], currentDocument: nil, texts: [:], language: "en")
        request.webEnabled = false
        let progress = Progress()
        let reply = try await NotesProviderTransport(store: LocalMediaStore(workspace: workspace)).sendNotebook(request, configuration: configuration, progress: { await progress.record($0) })
        let titles = await progress.events.map(\.id)
        print("LIVE_CLAUDE reply=\(reply.reply) events=\(titles) probe=\(String(format: "%.1f", probe.elapsedSeconds))s")
        XCTAssertTrue(reply.reply.lowercased().contains("ready"))
        XCTAssertTrue(reply.edits.isEmpty)
    }
}
