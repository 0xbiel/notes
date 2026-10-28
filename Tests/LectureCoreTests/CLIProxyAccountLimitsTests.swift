import XCTest
@testable import LectureCore

final class CLIProxyAccountLimitsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private var configuration: AIProviderConfiguration { .init(provider: .codexCLI, executablePath: "/unused/codex") }

    func testAccountsKeepSeparatePercentagesAndRealWindowDurations() {
        let payload: [String: Any] = ["connected": true, "accounts": [
            ["id": "paid", "provider": "codex", "email": "private@example.com", "quota": ["plan": "prolite", "checkedAt": now.timeIntervalSince1970 * 1_000,
                "windows": [["kind": "weekly", "duration": 604_800, "remaining": 86, "resetAt": 1_800_010_000_000.0]]]],
            ["id": "free", "provider": "codex", "label": "Personal", "quota": ["plan": "free", "checkedAt": now.timeIntervalSince1970 * 1_000,
                "windows": [["kind": "weekly", "label": "Monthly limit", "duration": 2_592_000, "remaining": 100]]]],
            ["id": "other", "provider": "claude", "quota": ["windows": [["remaining": 20]]]]]]
        let limits = CLIProxyAccountLimits.parse(payload, configuration: configuration, now: now)
        XCTAssertEqual(limits.source, "CLIProxyAPI")
        XCTAssertTrue(limits.windows.isEmpty)
        XCTAssertEqual(limits.accounts.map(\.id), ["paid", "free"])
        XCTAssertEqual(limits.accounts[0].windows[0].leftPercent, 86)
        XCTAssertEqual(limits.accounts[1].windows[0].leftPercent, 100)
        XCTAssertEqual(limits.accounts.map { $0.windows[0].kind }, [.weekly, .monthly])
        XCTAssertEqual(limits.accounts[0].windows[0].resetsAt, Date(timeIntervalSince1970: 1_800_010_000))
        XCTAssertEqual(limits.accounts[0].checked, now)
        XCTAssertFalse(limits.accounts[0].name.contains("private"))
        XCTAssertNil(limits.accounts[0].message)
    }

    func testPausedStaleAndMissingLimitsRemainExplicit() {
        let payload: [String: Any] = ["connected": true, "accounts": [
            ["id": "paused", "provider": "codex", "disabled": true, "quota": ["windows": [["remaining": 99]]]],
            ["id": "stale", "provider": "codex", "quota": ["checkedAt": now.addingTimeInterval(-601).timeIntervalSince1970 * 1_000, "windows": [["remaining": 30]]]],
            ["id": "unknown", "provider": "codex", "quota": ["windows": [["remaining": NSNull()], ["remaining": true], ["remaining": -1], ["remaining": "100"], ["remaining": 101]]]]]]
        let accounts = CLIProxyAccountLimits.parse(payload, configuration: configuration, now: now).accounts
        XCTAssertTrue(accounts[0].message?.contains("pausada") == true)
        XCTAssertTrue(accounts[1].message?.contains("desactualizados") == true)
        XCTAssertEqual(accounts[1].windows[0].leftPercent, 30)
        XCTAssertTrue(accounts[2].windows.isEmpty)
        XCTAssertNotNil(accounts[2].message)
    }

    func testClaudeWindowsAndDisconnectedSnapshots() {
        var config = configuration; config.provider = .claudeCode
        let limits = CLIProxyAccountLimits.parse(["connected": false, "accounts": [["id": "c", "provider": "anthropic", "quota": ["checkedAt": now.timeIntervalSince1970 * 1_000,
            "windows": [["kind": "short", "duration": 18_000, "remaining": 0], ["kind": "weekly", "duration": 604_800, "remaining": 51]]]]]], configuration: config, now: now)
        XCTAssertEqual(limits.accounts[0].windows.map(\.kind), [.session, .weekly])
        XCTAssertEqual(limits.accounts[0].windows[0].leftPercent, 0)
        XCTAssertNotNil(limits.message)
        XCTAssertNotNil(limits.accounts[0].message)
    }

    func testDashboardDiscoveryDoesNotReadCredentialsOrDependOnT3() throws {
        var config = configuration
        XCTAssertNil(CLIProxyAccountLimits.endpoint(config))
        config.executablePath = "/Users/example/Library/Application Support/CLIProxyAPI/codex-proxy"
        XCTAssertEqual(CLIProxyAccountLimits.endpoint(config)?.absoluteString, "http://127.0.0.1:8318/api/state")
        config.proxyUsageURL = "https://proxy.example.com/dashboard"
        XCTAssertEqual(CLIProxyAccountLimits.endpoint(config)?.absoluteString, config.proxyUsageURL)
        config.proxyUsageURL = "http://localhost:9321"
        XCTAssertEqual(CLIProxyAccountLimits.endpoint(config)?.path, "/api/state")
        XCTAssertThrowsError(try { config.proxyUsageURL = "http://remote.example.com"; try config.validate() }())
        XCTAssertNil(CLIProxyAccountLimits.dashboardURL("https://user:secret@example.com"))
        XCTAssertNil(CLIProxyAccountLimits.dashboardURL("https://example.com?token=secret"))
    }
    func testLiveDashboardReadsBothAccountPoolsWithoutCLIAuthentication() async throws {
        guard ProcessInfo.processInfo.environment["NOTES_LIVE_CLIPROXY_LIMITS"] == "1" else { throw XCTSkip("Explicit local CLIProxyAPI dashboard test") }
        for provider in [NotesAIProvider.codexCLI, .claudeCode] {
            let config = AIProviderConfiguration(provider: provider, executablePath: "/unused/provider")
            let limits = try await CLIProxyAccountLimits.read(config, endpoint: URL(string: "http://127.0.0.1:8318/api/state")!)
            XCTAssertEqual(limits.source, "CLIProxyAPI")
            XCTAssertFalse(limits.accounts.isEmpty)
            XCTAssertTrue(limits.accounts.contains { !$0.windows.isEmpty })
            XCTAssertTrue(limits.accounts.allSatisfy { $0.checked != nil })
        }
    }

}
