import XCTest
@testable import LectureCore

final class ProviderRuntimeTests: XCTestCase {
    func testFreshSettingsDoNotDiscoverT3() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let binary = home.appendingPathComponent(".t3/tools/codex/999/bin/codex")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let settings = AIProviderSettings(home: home)
        for provider in NotesAIProvider.allCases {
            XCTAssertFalse(settings[provider].executablePath.contains("/.t3/"))
            XCTAssertFalse(settings[provider].homePath.contains("/.t3/"))
        }
    }

    func testProxySettingsSurviveIsolatedHomeWithoutTools() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let account = root.appendingPathComponent("account")
        try FileManager.default.createDirectory(at: account, withIntermediateDirectories: true)
        let config = """
        model = "proxy-model"
        model_provider = "cliproxy"
        developer_instructions = "untrusted instructions"
        [model_providers.cliproxy]
        name = "CLIProxy"
        base_url = "http://localhost:8317/v1"
        wire_api = "responses"
        env_key = "PROXY_API_KEY"
        [mcp_servers.untrusted]
        command = "untrusted-tool"
        [features]
        shell_tool = true
        """
        try Data(config.utf8).write(to: account.appendingPathComponent("config.toml"))
        try Data("{}".utf8).write(to: account.appendingPathComponent("auth.json"))
        let configuration = AIProviderConfiguration(provider: .codexCLI, executablePath: "/manual/codex", homePath: account.path)
        let home = try CodexNotebookStreamingTransport.accountHome(configuration, in: root)
        let isolated = try String(contentsOf: home.appendingPathComponent("config.toml"), encoding: .utf8)
        XCTAssertTrue(isolated.contains("model_provider = \"cliproxy\""))
        XCTAssertTrue(isolated.contains("http://localhost:8317/v1"))
        XCTAssertTrue(isolated.contains("PROXY_API_KEY"))
        XCTAssertFalse(isolated.contains("untrusted"))
        XCTAssertFalse(isolated.contains("shell_tool"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent("auth.json").path))
    }

    func testMissingManualBinaryIsNotAutomaticallyReplaced() async throws {
        let configuration = AIProviderConfiguration(provider: .codexCLI, executablePath: "/missing/manual/codex")
        try await ProviderRuntime.shared.prepare(configuration)
        XCTAssertEqual(configuration.executablePath, "/missing/manual/codex")
    }
}
