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

    func testCodexThreadTotalSeparatesCachedInput() throws {
        var decoder = CodexNotebookProgressDecoder(threadID: "thread", model: "gpt-6-luna")
        XCTAssertNil(try decoder.accept("thread/tokenUsage/updated", ["threadId": "other", "tokenUsage": ["total": ["inputTokens": 9, "outputTokens": 9]]]))
        XCTAssertNil(decoder.usage)
        XCTAssertNil(try decoder.accept("thread/tokenUsage/updated", ["threadId": "thread", "turnId": "turn", "tokenUsage": [
            "total": ["inputTokens": 1_000, "cachedInputTokens": 800, "outputTokens": 120, "reasoningOutputTokens": 70, "totalTokens": 1_120],
            "last": ["inputTokens": 1, "outputTokens": 1]]]))
        XCTAssertEqual(decoder.usage, .init(model: "gpt-6-luna", input: 200, cachedInput: 800, output: 120))
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
