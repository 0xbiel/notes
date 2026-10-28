import XCTest
@testable import LectureCore

final class OpenCodeCompatibilityTests: XCTestCase {
    private func environment() throws -> (SafeWorkspace, URL) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".test-workspaces/OpenCode-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("copied-course"), withIntermediateDirectories: true)
        return (try SafeWorkspace(root: root, originalRoot: root.appendingPathComponent("original")), root)
    }

    func testNewOpenCodeReleaseUsesCapabilityAndEffectiveConfigurationChecks() async throws {
        let (workspace, root) = try environment()
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("opencode")
        try """
        #!/usr/bin/python3
        import sys,os
        args=sys.argv[1:]
        if args==['--pure','run','--help']: print('--format --agent --model --title', file=sys.stderr)
        elif args==['--pure','debug','config']: print(os.environ['OPENCODE_CONFIG_CONTENT'])
        else: sys.exit(1)
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let harness = OpenRouterHarness(store: LocalMediaStore(workspace: workspace), executablePath: script.path)
        try await harness.prepare()
        try "#!/bin/sh\necho '--agent --model --title'\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        do { try await harness.prepare(); XCTFail("Missing JSON transport must be rejected") }
        catch { XCTAssertTrue(error.localizedDescription.contains("transporte JSON")) }
    }

    func testLiveManagedOpenCodeConfigurationWithoutSendingContent() async throws {
        guard ProcessInfo.processInfo.environment["NOTES_LIVE_MANAGED_OPENCODE"] == "1" else { throw XCTSkip("Explicit managed OpenCode diagnostic") }
        let (workspace, root) = try environment()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = AIProviderConfiguration(provider: .openCode, executablePath: ProviderRuntime.managedExecutable(.openCode), model: OpenRouterHarness.model)
        for notebook in [false, true] {
            let harness = OpenRouterHarness(store: LocalMediaStore(workspace: workspace), configuration: configuration, notebookEditing: notebook)
            do { try await harness.prepare() }
            catch { XCTFail("OpenCode notebook mode \(notebook): \(error.localizedDescription)") }
        }
    }
    func testLiveManagedOpenCodeConnection() async throws {
        guard ProcessInfo.processInfo.environment["NOTES_LIVE_MANAGED_OPENCODE_CONNECTION"] == "1" else { throw XCTSkip("Explicit synthetic managed OpenCode connection test") }
        let (workspace, root) = try environment()
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = OpenRouterHarness(store: LocalMediaStore(workspace: workspace), executablePath: ProviderRuntime.managedExecutable(.openCode))
        try ProviderConnectionTest.validateReply(try await harness.connectionProbe())
    }

}
