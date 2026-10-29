import XCTest
@testable import LectureCore

final class NotebookCommandTests: XCTestCase {
    func testCommandWritesFileAndReturnsOutputAndFailureStatus() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let result = try await NotebookCommandRunner.run(.init(command: "printf 'summary' > result.txt; printf 'output'; printf 'error' >&2; exit 7"), defaultDirectory: root)
        XCTAssertEqual(result.exitCode, 7)
        XCTAssertTrue(result.output.contains("output"))
        XCTAssertTrue(result.output.contains("error"))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("result.txt"), encoding: .utf8), "summary")
    }

    func testPermissionsNeverAutoApproveShellSyntaxOutsideFullAccess() {
        for policy in [AIEditAutonomy.review, .edits, .automatic, .additions] {
            for script in ["pwd; touch marker", "$(touch marker)", "ls > marker", "git diff", "/bin/ls\ntouch marker"] {
                XCTAssertFalse(policy.approvesCommand(.init(command: script)))
            }
        }
        XCTAssertTrue(AIEditAutonomy.automatic.approvesCommand(.init(command: "pwd")))
        XCTAssertFalse(AIEditAutonomy.edits.approvesCommand(.init(command: "pwd")))
        XCTAssertTrue(AIEditAutonomy.fullAccess.approvesCommand(.init(command: "touch marker")))
        XCTAssertFalse(AIEditAutonomy.review.approvesFileChanges)
        XCTAssertTrue(AIEditAutonomy.edits.approvesFileChanges)
    }

    func testCancellationStopsCommandPromptly() async throws {
        let task = Task { try await NotebookCommandRunner.run(.init(command: "sleep 30 & wait"), defaultDirectory: FileManager.default.temporaryDirectory) }
        try await Task.sleep(for: .milliseconds(100))
        let start = Date()
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled command succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testResponseProtocolSeparatesCommandsFromOtherActions() throws {
        let response = NotebookAssistantResponse(reply: "", commands: [.init(command: "pwd")], pendingTasks: ["Summarize all three topics"])
        let encoded = String(decoding: try JSONEncoder().encode(response), as: UTF8.self)
        let decoded = try NotebookAssistantProtocol.decode(encoded)
        XCTAssertEqual(decoded.commands, response.commands)
        XCTAssertEqual(decoded.pendingTasks, response.pendingTasks)
        var mixed = response
        mixed.edits = [.init(path: "Note.md", replacement: "text", create: true)]
        XCTAssertThrowsError(try NotebookAssistantProtocol.decode(String(decoding: JSONEncoder().encode(mixed), as: UTF8.self)))
    }
}
