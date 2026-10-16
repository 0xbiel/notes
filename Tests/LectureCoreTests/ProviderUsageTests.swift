import XCTest
@testable import LectureCore

final class ProviderUsageTests: XCTestCase {
    private func workspace() throws -> SafeWorkspace {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".test-workspaces/Usage-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("copied-course"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try SafeWorkspace(root: root, originalRoot: root.appendingPathComponent("original"))
    }

    func testClaudeResultReportsTokensPerModel() throws {
        func line(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
        var decoder = ClaudeStreamDecoder()
        _ = try decoder.accept(line(["type": "system", "subtype": "init", "tools": ["StructuredOutput"], "mcp_servers": [], "model": "claude-haiku-5-5"]))
        _ = try decoder.accept(line(["type": "result", "subtype": "success", "is_error": false, "structured_output": ["ok": true], "total_cost_usd": 0.5,
                                     "usage": ["input_tokens": 10, "cache_read_input_tokens": 200, "cache_creation_input_tokens": 30, "output_tokens": 40],
                                     "modelUsage": ["claude-haiku-5-5-20260301": ["inputTokens": 10, "cacheReadInputTokens": 200, "cacheCreationInputTokens": 30, "outputTokens": 40, "costUSD": 0.25]]]))
        XCTAssertEqual(decoder.usage, [.init(model: "claude-haiku-5-5-20260301", input: 10, cachedInput: 200, cacheWrite: 30, output: 40, reportedCost: 0.25)])

        // Without the per-model table the total is attributed to the session's model; a failed result still counts.
        var failed = ClaudeStreamDecoder()
        _ = try failed.accept(line(["type": "system", "subtype": "init", "tools": [String](), "mcp_servers": [], "model": "claude-opus-5-5"]))
        XCTAssertThrowsError(try failed.accept(line(["type": "result", "subtype": "error_max_turns", "is_error": true, "usage": ["input_tokens": 7, "output_tokens": 3]])))
        XCTAssertEqual(failed.usage, [.init(model: "claude-opus-5-5", input: 7, output: 3)])
    }

    func testClaudeStreamsThinkingSummariesIntoOneThought() throws {
        func line(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
        func stream(_ event: [String: Any]) throws -> Data { try line(["type": "stream_event", "event": event]) }
        let configuration = AIProviderConfiguration(provider: .claudeCode, executablePath: "/usr/bin/true")
        let arguments = try ClaudeTextTransport.arguments(configuration, schema: [:], instructions: "x")
        XCTAssertTrue(arguments.contains("--include-partial-messages"))
        XCTAssertEqual(arguments.firstIndex(of: "--thinking-display").map { arguments[$0 + 1] }, "summarized")
        XCTAssertTrue(arguments[arguments.firstIndex(of: "--settings")! + 1].contains("showThinkingSummaries"))
        var custom = configuration
        custom.launchArguments = "--thinking disabled"
        XCTAssertFalse(try ClaudeTextTransport.arguments(custom, schema: [:], instructions: "x").contains("--thinking-display"))

        var decoder = ClaudeStreamDecoder()
        _ = try decoder.accept(line(["type": "system", "subtype": "init", "tools": ["StructuredOutput"], "mcp_servers": [], "model": "claude-sonnet-5-5"]))
        XCTAssertNil(try decoder.accept(line(["type": "system", "subtype": "status"])))
        let started = try decoder.accept(stream(["type": "content_block_start", "index": 0, "content_block": ["type": "thinking", "thinking": ""]]))
        XCTAssertEqual(started?.kind, .reasoning)
        XCTAssertNil(started?.detail)
        XCTAssertNil(try decoder.accept(stream(["type": "content_block_delta", "index": 0, "delta": ["type": "thinking_delta", "thinking": "Check "]])))
        // Short deltas are held back and shown together.
        XCTAssertNil(try decoder.accept(stream(["type": "content_block_delta", "index": 0, "delta": ["type": "thinking_delta", "thinking": "the dates."]])))
        XCTAssertNil(try decoder.accept(stream(["type": "content_block_delta", "index": 0, "delta": ["type": "signature_delta", "signature": "s"]])))
        let delta = try decoder.accept(stream(["type": "content_block_stop", "index": 0]))
        XCTAssertEqual(delta?.detail, "Check the dates.")
        XCTAssertEqual(delta?.id, started?.id)
        XCTAssertNil(try decoder.accept(stream(["type": "content_block_stop", "index": 0])))
        XCTAssertNil(try decoder.accept(stream(["type": "content_block_delta", "index": 1, "delta": ["type": "text_delta", "text": "Answer"]])))
        // The complete message repeats the block; it settles the same thought.
        let final = try decoder.accept(line(["type": "assistant", "message": ["content": [["type": "thinking", "thinking": "Check the dates. Done."]]]]))
        XCTAssertEqual(final?.id, started?.id)
        XCTAssertEqual(final?.detail, "Check the dates. Done.")
        let later = try decoder.accept(line(["type": "assistant", "message": ["content": [["type": "thinking", "thinking": "Second"]]]]))
        XCTAssertNotEqual(later?.id, started?.id)
    }

    func testResponseStreamNamesTheDocumentBeingWritten() throws {
        let body = String(repeating: "Línea \\\"citada\\\" del tema.\\n", count: 40)
        let json = #"{"reply":"Listo, he creado la nota.","readFiles":[],"webActions":[{"kind":"search","query":"q","url":"","path":"ignored.png"}],"edits":[{"path":"UD2/Resumen.md","find":"","replacement":""# + body + #"","create":true},{"path":"UD2/Otra.md","find":"","replacement":"x"}],"outputs":[]}"#
        var stream = NotebookResponseStream(), updates: [NotebookProviderProgress] = []
        var index = json.startIndex
        // Deltas split the text anywhere, including inside escapes.
        while index < json.endIndex {
            let end = json.index(index, offsetBy: 7, limitedBy: json.endIndex) ?? json.endIndex
            if let update = stream.accept(String(json[index..<end])) { updates.append(update) }
            index = end
        }
        XCTAssertFalse(updates.contains { $0.title.contains("ignored.png") })
        let first = try XCTUnwrap(updates.first { $0.title == "Redactando · UD2/Resumen.md" })
        let writing = updates.filter { $0.id == first.id }
        XCTAssertGreaterThan(writing.count, 3)
        XCTAssertTrue(writing.last?.detail?.contains("Línea \"citada\" del tema.\n") == true)
        XCTAssertEqual(writing.map { $0.written ?? 0 }, writing.map { $0.written ?? 0 }.sorted())
        let second = try XCTUnwrap(updates.last { $0.title == "Redactando · UD2/Otra.md" })
        XCTAssertNotEqual(second.id, first.id)
        XCTAssertNil(second.detail)

        // Codex deltas and Claude's tool-call input feed the same reader.
        var codex = CodexNotebookProgressDecoder(threadID: "t")
        XCTAssertEqual(try codex.accept("item/agentMessage/delta", ["threadId": "t", "delta": #"{"reply":""#])?.title, "Redactando respuesta…")
        XCTAssertNil(try codex.accept("item/agentMessage/delta", ["threadId": "t", "delta": "Hola"]))
        XCTAssertEqual(try codex.accept("item/agentMessage/delta", ["threadId": "t", "delta": #"","edits":[{"path":"A.md","#])?.title, "Redactando · A.md")
        func event(_ event: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: ["type": "stream_event", "event": event]) }
        var claude = ClaudeStreamDecoder()
        _ = try claude.accept(JSONSerialization.data(withJSONObject: ["type": "system", "subtype": "init", "tools": ["StructuredOutput"], "mcp_servers": [], "model": "m"]))
        XCTAssertNil(try claude.accept(event(["type": "content_block_start", "index": 2, "content_block": ["type": "tool_use", "name": "StructuredOutput", "input": [String: Any]()]])))
        XCTAssertEqual(try claude.accept(event(["type": "content_block_delta", "index": 2, "delta": ["type": "input_json_delta", "partial_json": #"{"reply":"","edits":[{"path":"B.md","replacement":"abc"#]]))?.title, "Redactando · B.md")
        XCTAssertNil(try claude.accept(JSONSerialization.data(withJSONObject: ["type": "assistant", "message": ["content": [["type": "tool_use", "name": "StructuredOutput", "input": [String: Any]()]]]])))
    }

    func testProviderLimitsAreReadFromEachProvidersAnswer() throws {
        let claude = ProviderLimitsProbe.claude(["subscription_type": "pro", "rate_limits_available": true, "rate_limits": [
            "five_hour": ["utilization": 32, "resets_at": "2026-10-13T11:09:59.827216+00:00"], "seven_day": ["utilization": 123, "resets_at": NSNull()], "seven_day_opus": NSNull(),
            "limits": [["kind": "session", "percent": 32], ["kind": "weekly_scoped", "percent": 40, "resets_at": "2026-10-16T14:59:59Z", "scope": ["model": ["display_name": "Fable"]]]]]])
        XCTAssertEqual(claude.plan, "pro")
        XCTAssertEqual(claude.windows.map(\.id), ["five_hour", "seven_day", "seven_day_fable"])
        XCTAssertEqual(claude.windows[0].leftPercent, 68)
        XCTAssertEqual(claude.windows[0].resetsAt, Date(timeIntervalSince1970: 1_791_889_799))
        XCTAssertEqual(claude.windows[1].usedPercent, 100)
        XCTAssertNil(claude.windows[1].resetsAt)
        XCTAssertEqual(claude.windows[2].scope, "Fable")
        XCTAssertTrue(ProviderLimitsProbe.claude(["rate_limits_available": false]).windows.isEmpty)

        let window: [String: Any] = ["usedPercent": 2, "windowDurationMins": 10_080, "resetsAt": 1_792_474_666]
        let codex = ProviderLimitsProbe.codex(["rateLimits": ["planType": "free", "primary": ["usedPercent": 90]], "rateLimitsByLimitId": ["codex": ["planType": "prolite", "primary": window, "secondary": NSNull()]]])
        XCTAssertEqual(codex.plan, "prolite")
        XCTAssertEqual(codex.windows, [.init(id: "primary", kind: .weekly, usedPercent: 2, resetsAt: Date(timeIntervalSince1970: 1_792_474_666))])
        XCTAssertEqual(ProviderLimitsProbe.codex(["rateLimits": ["planType": "plus", "primary": ["usedPercent": 10], "secondary": ["usedPercent": 20]]]).windows.map(\.kind), [.session, .weekly])
        XCTAssertEqual(ProviderLimitsProbe.codex(["rateLimits": ["planType": "free", "primary": ["usedPercent": 10]]]).windows.map(\.kind), [.monthly])

        let summary = ProviderLimitsProbe.antigravity(summary: ["groups": [["displayName": "Models", "buckets": [
            ["bucketId": "3p-weekly", "window": "weekly", "remainingFraction": 0.25, "resetTime": "2026-10-20T00:00:00Z"], ["bucketId": "gemini-5h", "window": "5h", "remainingFraction": 1],
            ["bucketId": "off", "disabled": true, "remainingFraction": 1], ["bucketId": "unknown"]]]]])
        XCTAssertEqual(summary.map(\.id), ["gemini-5h", "3p-weekly"])
        XCTAssertEqual(summary.map(\.scope), ["Gemini", "Claude & GPT"])
        XCTAssertEqual(summary.map(\.kind), [.session, .weekly])
        XCTAssertEqual(summary.map(\.usedPercent), [0, 75])
        // The account's real shape: Gemini, Claude and GPT, and a separate Gemini 4 Argon allowance.
        let groups = ProviderLimitsProbe.antigravity(summary: ["groups": [
            ["displayName": "Gemini Models", "buckets": [["bucketId": "gemini-weekly", "window": "weekly", "remainingFraction": 1], ["bucketId": "gemini-5h", "window": "5h", "remainingFraction": 1]]],
            ["displayName": "Claude and GPT models", "buckets": [["bucketId": "3p-weekly", "window": "weekly", "remainingFraction": 0.97], ["bucketId": "3p-5h", "window": "5h", "remainingFraction": 0.93]]],
            ["displayName": "Gemini 4 Argon", "buckets": [["bucketId": "gemini-argon-wtu-weekly", "displayName": "Gemini 4 Argon Weekly Limit", "window": "weekly", "remainingFraction": 0.83]]]]])
        XCTAssertEqual(groups.map(\.scope), ["Gemini", "Gemini", "Claude & GPT", "Claude & GPT", "Gemini 4 Argon"])
        XCTAssertEqual(groups.map(\.kind), [.session, .weekly, .session, .weekly, .weekly])
        XCTAssertEqual(groups.last?.usedPercent ?? 0, 17, accuracy: 0.001)
        let models = ProviderLimitsProbe.antigravity(models: ["models": ["gemini-3-pro": ["quotaInfo": ["remainingFraction": 0.5]], "gemini-3-flash": ["quotaInfo": ["remainingFraction": 0.9]], "claude-x": ["weeklyQuotaInfo": ["remainingFraction": 0.2]], "other": ["quotaInfo": ["remainingFraction": 0]]]])
        XCTAssertEqual(models.map(\.id), ["claude-weekly", "gemini-quota"])
        XCTAssertEqual(models.map(\.usedPercent), [80, 50])

    }

    func testSummarySplitsEachBucketByProvider() {
        let calendar = Calendar(identifier: .gregorian), now = Date(timeIntervalSince1970: 1_800_000_000)
        let records = [ProviderUsageRecord(date: now, provider: .codexCLI, notebookID: "n", usage: .init(model: "gpt-6-sol", input: 1_000_000, cachedInput: 1_000_000)),
                       ProviderUsageRecord(date: now, provider: .claudeCode, notebookID: "n", usage: .init(model: "claude-sonnet-5-5", output: 100_000)),
                       ProviderUsageRecord(date: now.addingTimeInterval(-86_400), provider: nil, notebookID: "n", usage: .init(model: "old", input: 10))]
        let summary = ProviderUsageSummary(records: records, days: 90, now: now, calendar: calendar)
        XCTAssertEqual(summary.buckets.count, 90)
        XCTAssertEqual(summary.providers.map(\.id), ["codexCLI", "claudeCode", "unknown"])
        let today = summary.buckets[89]
        XCTAssertEqual(today.providers["codexCLI"], .init(cost: 2.2, tokens: 2_000_000))
        XCTAssertEqual(today.providers["claudeCode"], .init(cost: 1, tokens: 100_000))
        XCTAssertEqual(today.providers.values.map(\.tokens).reduce(0, +), today.tokens)
        XCTAssertEqual(summary.buckets[88].providers, ["unknown": .init(cost: 0, tokens: 10)])
        XCTAssertEqual(summary.cacheSavings, 1.8, accuracy: 0.0001)
    }

    func testLiveProviderLimits() async throws {
        guard ProcessInfo.processInfo.environment["NOTES_LIMIT_PROBES"] == "1" else { throw XCTSkip("Set NOTES_LIMIT_PROBES=1 to read the installed accounts' limits.") }
        let settings = AIProviderSettings(), store = LocalMediaStore(workspace: try workspace())
        for provider in [NotesAIProvider.claudeCode, .codexCLI, .antigravity] {
            let limits = await ProviderLimitsProbe.read(settings.configuration(for: provider), store: store)
            print("LIMITS", provider.rawValue, limits.plan ?? "-", limits.windows.map { "\($0.id) \($0.kind.rawValue) \($0.scope ?? "") left=\(Int($0.leftPercent)) reset=\($0.resetsAt.map { Int($0.timeIntervalSinceNow / 60) } ?? -1)m" }, limits.message ?? "")
            XCTAssertFalse(limits.windows.isEmpty, limits.message ?? "")
        }
    }

    func testLogDeduplicatesIdentityButKeepsDistinctIdenticalRequests() throws {
        let workspace = try workspace(), log = ProviderUsageLog(workspace: workspace)
        let first = ProviderUsageRecord(date: Date(timeIntervalSince1970: 1_800_000_000), provider: .codexCLI, notebookID: "n", usage: .init(model: "gpt-6-sol", input: 100))
        var second = first
        second.id = UUID().uuidString
        try log.append([first, first, second])
        try log.append([first, second])
        XCTAssertEqual(log.records(), [first, second])
        let data = try workspace.readStorage(ProviderUsageLog.path)
        try workspace.writeStorage(ProviderUsageLog.path, data: data + data)
        XCTAssertEqual(log.records(), [first, second])
    }

    func testHistoricalUsageSurvivesChatAndNotebookDeletionWithoutRecounting() throws {
        let workspace = try workspace(), log = ProviderUsageLog(workspace: workspace)
        var chat = NotebookChat()
        chat.messages = [.init(role: "user", text: "Question"), .init(role: "assistant", text: "Answer")]
        var state = NotebookProjectState()
        state.chats = [chat]
        let store = try NotebookProjectStore(workspace: workspace, notebooks: [.copiedCourse])
        try store.saveState(state, notebookID: Notebook.copiedCourse.id)
        let records = log.records()
        XCTAssertEqual(records.count, 1)
        XCTAssertNil(records.first?.provider)
        XCTAssertEqual(records.first?.usage.estimated, true)
        XCTAssertNil(ProviderUsagePricing.cost(try XCTUnwrap(records.first?.usage)))
        _ = try store.loadState(.copiedCourse)
        try store.saveState(state, notebookID: Notebook.copiedCourse.id)
        try log.cacheHistory(state, notebookID: "copied-notebook")
        XCTAssertEqual(log.records(), records)
        state.chats = []
        try store.saveState(state, notebookID: Notebook.copiedCourse.id)
        try store.forgetNotebook(Notebook.copiedCourse.id)
        XCTAssertEqual(ProviderUsageLog(workspace: workspace).records(), records)
    }

    func testHistoryDoesNotRecountLoggedOrTrackedTurnsOrUnsentMessages() throws {
        let workspace = try workspace(), log = ProviderUsageLog(workspace: workspace)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        var prompt = NotebookMessage(role: "user", text: "Question")
        prompt.date = date.addingTimeInterval(-10)
        var reply = NotebookMessage(role: "assistant", text: "Answer")
        reply.date = date.addingTimeInterval(10)
        var chat = NotebookChat()
        chat.messages = [prompt, reply]
        var state = NotebookProjectState()
        state.chats = [chat]
        var record = ProviderUsageRecord(date: date, provider: .claudeCode, notebookID: "n", usage: .init(model: "claude", input: 50))
        record.id = nil
        try log.append([record])
        try log.cacheHistory(state, notebookID: "n")
        prompt.usageTracked = true
        state.chats[0].messages = [prompt, reply, .init(role: "error", text: "Failed"), .init(role: "user", text: "Unsent")]
        try log.cacheHistory(state, notebookID: "other")
        XCTAssertEqual(log.records(), [record])
    }

    func testAppendingAfterDamagedUnterminatedLinePreservesNewRecord() throws {
        let workspace = try workspace(), log = ProviderUsageLog(workspace: workspace)
        try workspace.writeStorage(ProviderUsageLog.path, data: Data("{broken".utf8))
        let record = ProviderUsageRecord(date: Date(timeIntervalSince1970: 1_800_000_000), provider: .codexCLI, notebookID: "n", usage: .init(model: "default", output: 10))
        try log.append([record])
        XCTAssertEqual(log.records(), [record])
    }

    func testDistinctHistoricalChatsWithOverlappingDatesAreNotDeduplicated() throws {
        let workspace = try workspace(), log = ProviderUsageLog(workspace: workspace)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        var state = NotebookProjectState()
        for _ in 0..<2 {
            var chat = NotebookChat()
            var prompt = NotebookMessage(role: "user", text: "Same question")
            prompt.date = date
            var reply = NotebookMessage(role: "assistant", text: "Same answer")
            reply.date = date.addingTimeInterval(10)
            chat.messages = [prompt, reply]
            state.chats.append(chat)
            try log.cacheHistory(state, notebookID: "n")
        }
        try log.cacheHistory(state, notebookID: "n")
        XCTAssertEqual(log.records().count, 2)
    }

    func testCodexThreadTotalSeparatesCachedInput() throws {
        var decoder = CodexNotebookProgressDecoder(threadID: "thread", model: "gpt-6-luna")
        XCTAssertNil(try decoder.accept("thread/tokenUsage/updated", ["threadId": "other", "tokenUsage": ["total": ["inputTokens": 9, "outputTokens": 9]]]))
        XCTAssertNil(decoder.usage)
        let context = try decoder.accept("thread/tokenUsage/updated", ["threadId": "thread", "turnId": "turn", "tokenUsage": [
            "total": ["inputTokens": 1_000, "cachedInputTokens": 800, "outputTokens": 120, "reasoningOutputTokens": 70, "totalTokens": 1_120],
            "last": ["inputTokens": 1, "outputTokens": 1]]])
        XCTAssertEqual(context?.context?.usedTokens, 2)
        XCTAssertEqual(decoder.usage, .init(model: "gpt-6-luna", input: 200, cachedInput: 800, output: 120))
        var resumed = CodexNotebookProgressDecoder(threadID: "thread", model: "gpt-6-luna", initialUsage: decoder.cumulativeUsage)
        _ = try resumed.accept("thread/tokenUsage/updated", ["threadId": "thread", "tokenUsage": ["total": ["inputTokens": 1100, "cachedInputTokens": 850, "outputTokens": 140], "last": ["inputTokens": 50, "outputTokens": 20]]])
        XCTAssertEqual(resumed.usage, .init(model: "gpt-6-luna", input: 50, cachedInput: 50, output: 20))
    }

    func testAntigravityUsesReportedTokensOrApproximatesThem() {
        let reported = AntigravityTextTransport.usage(["stopReason": "end_turn", "usage": ["inputTokens": 500, "cachedReadTokens": 100, "outputTokens": 40, "thoughtTokens": 10]], model: "gemini-3.8-flash-high", prompt: "ignored", output: "ignored")
        XCTAssertEqual(reported, .init(model: "gemini-3.8-flash-high", input: 400, cachedInput: 100, output: 50))
        let approximate = AntigravityTextTransport.usage(["stopReason": "end_turn"], model: "gemini-pro-agent", prompt: String(repeating: "a", count: 400), output: String(repeating: "b", count: 41))
        XCTAssertEqual(approximate, .init(model: "gemini-pro-agent", input: 100, output: 11, estimated: true))
    }

    func testPricingMatchesModelVariantsAndPrefersReportedCost() throws {
        XCTAssertEqual(ProviderUsagePricing.rate(for: "claude-haiku-5-5-20260301")?.output, 0.5)
        XCTAssertEqual(ProviderUsagePricing.rate(for: "claude-opus-4-6[1m]")?.input, 5)
        XCTAssertEqual(ProviderUsagePricing.rate(for: "gemini-3.8-flash-high")?.input, 0.75)
        XCTAssertEqual(ProviderUsagePricing.rate(for: "openai/GPT-6-Sol")?.output, 10)
        XCTAssertNil(ProviderUsagePricing.rate(for: "gemini-pro-agent"))
        let usage = ProviderTokenUsage(model: "gpt-6-sol", input: 1_000_000, cachedInput: 2_000_000, output: 500_000)
        XCTAssertEqual(try XCTUnwrap(ProviderUsagePricing.cost(usage)), 2 + 0.4 + 5, accuracy: 1e-9)
        XCTAssertEqual(ProviderUsagePricing.cost(.init(model: "gpt-6-sol", input: 1_000_000, reportedCost: 0.75)), 0.75)
        XCTAssertNil(ProviderUsagePricing.cost(.init(model: "unknown", input: 10)))

        let document: [String: Any] = [
            "sample_spec": ["input_cost_per_token": 0, "litellm_provider": "one of"],
            "claude-next": ["litellm_provider": "anthropic", "input_cost_per_token": 3e-6, "output_cost_per_token": 15e-6, "cache_read_input_token_cost": 3e-7, "cache_creation_input_token_cost": 3.75e-6],
            "gemini/gemini-next": ["litellm_provider": "gemini", "input_cost_per_token": 1e-6, "output_cost_per_token": 4e-6],
            "azure/gpt-next": ["litellm_provider": "azure", "input_cost_per_token": 9e-6, "output_cost_per_token": 9e-6],
            "dall-e": ["litellm_provider": "openai", "output_cost_per_image": 0.04]
        ]
        let rates = try ProviderUsagePricing.rates(fromLiteLLM: JSONSerialization.data(withJSONObject: document))
        XCTAssertEqual(Set(rates.keys), ["claude-next", "gemini-next"])
        XCTAssertEqual(try XCTUnwrap(rates["claude-next"]?.cacheWrite), 3.75, accuracy: 1e-9)
        // A missing cache price falls back to the input price.
        XCTAssertEqual(try XCTUnwrap(rates["gemini-next"]?.cachedInput), 1, accuracy: 1e-9)
        XCTAssertThrowsError(try ProviderUsagePricing.rates(fromLiteLLM: Data("{}".utf8)))

        let workspace = try workspace()
        XCTAssertEqual(ProviderUsagePricing.rates(workspace), ProviderUsagePricing.builtIn)
        try ProviderUsagePricing.save(.init(fetched: Date(timeIntervalSince1970: 1_000), rates: ["gpt-6-sol": .init(input: 1, output: 2)]), workspace: workspace)
        XCTAssertEqual(ProviderUsagePricing.rates(workspace)["gpt-6-sol"]?.output, 2)
        XCTAssertEqual(ProviderUsagePricing.rates(workspace)["claude-haiku-5-5"], ProviderUsagePricing.builtIn["claude-haiku-5-5"])
        XCTAssertEqual(ProviderUsagePricing.cached(workspace)?.fetched, Date(timeIntervalSince1970: 1_000))
    }

    func testLogKeepsRecordsAndSummaryTotalsThePeriod() throws {
        let workspace = try workspace(), log = ProviderUsageLog(workspace: workspace)
        XCTAssertEqual(log.records(), [])
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15 08:00 UTC
        func record(_ provider: NotesAIProvider, _ usage: ProviderTokenUsage, hoursAgo: Double) -> ProviderUsageRecord {
            .init(date: now.addingTimeInterval(-hoursAgo * 3_600), provider: provider, notebookID: "n", usage: usage)
        }
        try log.append([record(.claudeCode, .init(model: "claude-haiku-5-5", input: 100, cachedInput: 900, output: 50, reportedCost: 0.02), hoursAgo: 1)])
        try log.append([
            record(.codexCLI, .init(model: "gpt-6-sol", input: 1_000_000, output: 100_000), hoursAgo: 30),
            record(.codexCLI, .init(model: "gpt-6-sol", input: 1_000_000, output: 100_000), hoursAgo: 2),
            record(.antigravity, .init(model: "gemini-pro-agent", input: 400, output: 100, estimated: true), hoursAgo: 3),
            record(.claudeCode, .init(model: "claude-haiku-5-5", input: 5, output: 5), hoursAgo: 24 * 40)
        ])
        // A damaged line does not hide the others.
        try workspace.writeStorage(ProviderUsageLog.path, data: try workspace.readStorage(ProviderUsageLog.path) + Data("{broken\n".utf8))
        let records = log.records()
        XCTAssertEqual(records.count, 5)

        let week = ProviderUsageSummary(records: records, days: 7, now: now, calendar: calendar)
        XCTAssertEqual(week.requests, 4)
        XCTAssertEqual(week.cost, 0.02 + 3 + 3, accuracy: 1e-9)
        XCTAssertEqual(week.rows.map(\.model), ["gpt-6-sol", "claude-haiku-5-5", "gemini-pro-agent"])
        XCTAssertEqual(week.rows[0].requests, 2)
        XCTAssertTrue(week.rows[2].unpriced && week.rows[2].estimated)
        XCTAssertEqual(week.unpricedTokens, 500)
        XCTAssertEqual(week.estimatedTokens, 500)
        XCTAssertEqual(week.cachedInput, 900)
        XCTAssertEqual(week.cacheHit, 900.0 / 2_001_400.0, accuracy: 1e-9)
        XCTAssertEqual(week.buckets.count, 7)
        XCTAssertEqual(week.buckets.last?.cost ?? 0, 3.02, accuracy: 1e-9)
        XCTAssertEqual(week.buckets[5].cost, 3, accuracy: 1e-9)

        let day = ProviderUsageSummary(records: records, days: 1, now: now, calendar: calendar)
        XCTAssertEqual(day.requests, 3)
        XCTAssertEqual(day.buckets.count, 24)
        XCTAssertEqual(day.buckets[22].tokens, 1_050)

        let all = ProviderUsageSummary(records: records, days: nil, now: now, calendar: calendar)
        XCTAssertEqual(all.requests, 5)
        XCTAssertEqual(all.buckets.count, 41)
        XCTAssertEqual(ProviderUsageSummary(records: [], days: nil, now: now, calendar: calendar).buckets.count, 1)
    }
}
