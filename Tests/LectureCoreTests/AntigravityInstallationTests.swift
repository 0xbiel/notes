import XCTest
@testable import LectureCore

final class AntigravityInstallationTests: XCTestCase {
    func testDetectionRepairsOnlyTheGeneratedPathUsingTheChosenHarness() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let binary = root.appendingPathComponent("agy_acp_server.par")
        try Data("#!/bin/sh\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        var settings = AIProviderSettings()
        settings.antigravity.executablePath = ProviderRuntime.managedExecutable(.antigravity)
        settings.antigravity.harnessPath = root.appendingPathComponent("localharness_external").path
        settings.antigravity.homePath = "/chosen/account"
        XCTAssertEqual(ProviderRuntime.detectedExecutable(for: settings.antigravity), binary.path)
        let repaired = try JSONDecoder().decode(AIProviderSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(repaired.antigravity.executablePath, binary.path)
        XCTAssertEqual(repaired.antigravity.homePath, "/chosen/account")
        settings.antigravity.executablePath = "/custom/missing/antigravity"
        let manual = try JSONDecoder().decode(AIProviderSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(manual.antigravity.executablePath, "/custom/missing/antigravity")
    }

    func testLiveConfiguredAntigravityConnection() async throws {
        guard ProcessInfo.processInfo.environment["NOTES_LIVE_ANTIGRAVITY_CONNECTION"] == "1" else { throw XCTSkip("Explicit synthetic Antigravity connection test") }
        let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Palladium")
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: library.appendingPathComponent("original-hashes.json"))) as! [String: Any]
        let workspace = try SafeWorkspace(root: library, originalRoot: URL(fileURLWithPath: manifest["originalRoot"] as! String))
        let configuration = try AIProviderSettings.load(in: workspace).antigravity
        XCTAssertTrue(ProviderRuntime.isInstalled(configuration))
        do {
            let result = try await ProviderConnectionTest.run(configuration)
            XCTAssertEqual(result.provider, .antigravity)
        } catch { XCTFail("Antigravity connection: \(error.localizedDescription)") }
    }
}
