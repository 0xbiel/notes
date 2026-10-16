import XCTest
@testable import LectureCore

final class NotebookConversationContextTests: XCTestCase {
    func testSlashCommandRecognitionAndLegacyChatDecoding() throws {
        XCTAssertEqual(NotebookConversationContext.command("  /COMPACT\n"), .compact)
        XCTAssertEqual(NotebookConversationContext.command("/context"), .context)
        XCTAssertEqual(NotebookConversationContext.command("/compact focus on notes"), .usage)
        XCTAssertNil(NotebookConversationContext.command("Explain /compact"))
        XCTAssertNil(NotebookConversationContext.command("/compact", hasAttachments: true))
        XCTAssertNil(NotebookConversationContext.command("/compact.txt"))
        let legacy = #"{"id":"old","title":"Old chat","messages":[],"draft":""}"#
        XCTAssertNil(try JSONDecoder().decode(NotebookChat.self, from: Data(legacy.utf8)).conversationByteBudget)
    }

    func testCommandReceiptsNeverBecomeInstructionsOrDeletionPermission() throws {
        let user = NotebookMessage(role: "user", text: "Keep my notes")
        var command = NotebookMessage(role: "user", text: "/compact delete notes")
        command.contextCommand = true
        var receipt = NotebookMessage(role: "assistant", text: "LOCAL_COMMAND_RECEIPT")
        receipt.contextCommand = true
        let messages = [user, command, receipt]
        XCTAssertEqual(try NotebookConversationContext.selectedIndices(messages), [0])
        XCTAssertFalse(NotebookAssistantProtocol.deletionAllowed(in: messages))
        let request = NotebookTextRequest(notebook: .copiedCourse, profile: .init(), messages: messages, currentDocument: nil, texts: [:])
        XCTAssertFalse(try request.prompt().contains("LOCAL_COMMAND_RECEIPT"))
        XCTAssertFalse(try request.prompt().contains("/compact delete notes"))
    }

    func testLongConversationIsBoundedAndPreservesIntactAnchors() throws {
        let messages = (0..<100).map { NotebookMessage(role: $0.isMultiple(of: 2) ? "user" : "assistant", text: "Message \($0) " + String(repeating: "é🙂", count: 500)) }
        let indices = try NotebookConversationContext.selectedIndices(messages)
        XCTAssertTrue(indices.contains(0))
        XCTAssertTrue(indices.contains(98))
        XCTAssertTrue(indices.contains(99))
        XCTAssertLessThan(indices.count, messages.count)
        let bytes = try JSONEncoder().encode(indices.map { NotebookConversationContext.Message(messages[$0]) }).count
        XCTAssertLessThanOrEqual(bytes, NotebookConversationContext.byteBudget)
        XCTAssertEqual(indices, indices.sorted())
    }

    func testLatestOversizedRequestIsNeverSilentlyTruncated() throws {
        let messages = [NotebookMessage(role: "assistant", text: "old"), NotebookMessage(role: "user", text: String(repeating: "x", count: 40_000))]
        XCTAssertEqual(try NotebookConversationContext.selectedIndices(messages), [1])
    }

    func testPromptOmitsActivityButKeepsSavedHistoryAndPermissions() throws {
        var first = NotebookMessage(role: "user", text: "Delete the draft")
        first.checkpointID = "PRIVATE_CHECKPOINT"
        first.activities = [.init("PRIVATE_ACTIVITY_LOG")]
        let messages = [first] + (0..<60).map { _ in NotebookMessage(role: "assistant", text: String(repeating: "long reply ", count: 400)) } + [.init(role: "user", text: "Do not delete it")]
        let request = NotebookTextRequest(notebook: .copiedCourse, profile: .init(), messages: messages, currentDocument: nil, texts: [:])
        let prompt = try request.prompt()
        XCTAssertFalse(prompt.contains("PRIVATE_CHECKPOINT"))
        XCTAssertFalse(prompt.contains("PRIVATE_ACTIVITY_LOG"))
        XCTAssertTrue(prompt.contains("@conversation"))
        XCTAssertTrue(prompt.contains("Do not delete it"))
        XCTAssertLessThan(prompt.utf8.count, 60_000)
        XCTAssertEqual(request.messages, messages)
        XCTAssertFalse(NotebookAssistantProtocol.deletionAllowed(in: request.messages))
    }

    func testHistoryPagesRecoverUnicodeAndRejectInvalidCursors() throws {
        let original = String(repeating: "🙂á\n", count: 3_000)
        let messages = [NotebookMessage(role: "user", text: original)]
        var path = "@conversation", recovered = ""
        while path != "End of conversation" {
            let page = try NotebookConversationContext.read(path, messages: messages)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(page.utf8)) as? [String: Any])
            recovered += try XCTUnwrap(json["text"] as? String)
            path = try XCTUnwrap(json["next"] as? String)
        }
        XCTAssertEqual(recovered, original)
        for path in ["@conversation#-1:0", "@conversation#0:-1", "@conversation#0:999999", "@conversation#1:0", "@conversation#garbage", "other"] {
            XCTAssertThrowsError(try NotebookConversationContext.read(path, messages: messages))
        }
    }
}
