import XCTest
@testable import LectureCore

final class NotebookResponseDiagnosticsTests: XCTestCase {
    private func workspace() throws -> SafeWorkspace {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".test-workspaces/Diagnostics-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("copied-course"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try SafeWorkspace(root: root, originalRoot: root.appendingPathComponent("original"))
    }

    private func json(_ response: NotebookAssistantResponse) throws -> String {
        String(decoding: try JSONEncoder().encode(response), as: UTF8.self)
    }

    private func failure(_ response: NotebookAssistantResponse) throws -> NotebookResponseValidationError {
        do { _ = try NotebookAssistantProtocol.decode(json(response)); XCTFail("Expected validation rejection") }
        catch let error as NotebookResponseValidationError { return error }
        throw MediaError.invalid("Expected validation rejection.")
    }

    func testLargeActionCountsAndEveryIncompatibleCombination() throws {
        let output = NotebookDocumentOutput(path: "figure.png", format: "image")
        let edit = NotebookEdit(path: "Note.md", replacement: "New", create: true)
        let web = NotebookWebAction(kind: "search", query: "invented", url: "")
        XCTAssertNoThrow(try NotebookAssistantProtocol.decode(json(.init(reply: "", edits: Array(repeating: edit, count: 301)))))
        XCTAssertNoThrow(try NotebookAssistantProtocol.decode(json(.init(reply: "", readFiles: Array(repeating: "Note.md", count: 31)))))
        XCTAssertNoThrow(try NotebookAssistantProtocol.decode(json(.init(reply: "", outputs: Array(repeating: output, count: 34)))))
        XCTAssertNoThrow(try NotebookAssistantProtocol.decode(json(.init(reply: "", webActions: Array(repeating: web, count: 4)))))
        let combinations: [(NotebookAssistantResponse, String)] = [
            (.init(reply: "", readFiles: ["Note.md"], outputs: [output]), "outputs_with_reads"),
            (.init(reply: "", webActions: [web], outputs: [output]), "outputs_with_web"),
            (.init(reply: "", readFiles: ["Note.md"], edits: [edit]), "reads_with_edits"),
            (.init(reply: "", edits: [edit], webActions: [web]), "web_with_edits"),
            (.init(reply: "", readFiles: ["Note.md"], webActions: [web]), "web_with_reads")
        ]
        for (response, code) in combinations { XCTAssertEqual(try failure(response).code, code) }
        XCTAssertNoThrow(try NotebookAssistantProtocol.decode(json(.init(reply: "", edits: [edit], outputs: Array(repeating: output, count: 10)))))
        XCTAssertNoThrow(try NotebookAssistantProtocol.decode(json(.init(reply: "", readFiles: Array(repeating: "Note.md", count: 30)))))
        XCTAssertNoThrow(try NotebookAssistantProtocol.decode(json(.init(reply: "", edits: Array(repeating: edit, count: 300)))))
        XCTAssertNoThrow(try NotebookAssistantProtocol.decode(json(.init(reply: "", webActions: Array(repeating: web, count: 3)))))
    }

    func testLargeResponseAndRequestAreNotCapped() throws {
        let text = String(repeating: "é", count: 500_001)
        XCTAssertEqual(try NotebookAssistantProtocol.decode(json(.init(reply: text))).reply, text)
        let request = NotebookTextRequest(notebook: Notebook(id: "invented", name: "Invented", rootPrefix: ""), profile: NotebookProfile(), messages: [.init(role: "user", text: text)], currentDocument: nil, texts: [:], language: "en")
        XCTAssertNoThrow(try request.prompt())
    }

    func testLargeEditBatchAndReplacementAreNotCapped() throws {
        let replacement = String(repeating: "é", count: 500_001)
        var edits = (1...301).map { NotebookEdit(path: "Note-\($0).md", replacement: "New", create: true) }
        edits[0].replacement = replacement
        let changes = try NotebookAssistantProtocol.changes(.init(reply: "", edits: edits), documents: [:])
        XCTAssertEqual(changes.count, 301)
        XCTAssertEqual(changes.first(where: { $0.path == "Note-1.md" })?.after, replacement)
    }

    func testCodexCompletedResponseIsNotTruncated() throws {
        let text = String(repeating: "é", count: 100_001)
        var decoder = CodexNotebookProgressDecoder(threadID: "invented")
        _ = try decoder.accept("item/completed", ["threadId": "invented", "item": ["type": "agentMessage", "text": text]])
        XCTAssertEqual(decoder.output, text)
    }

    func testMultiUnitQuizAndImagesAcceptsFullObservedCount() throws {
        let images = Array(repeating: NotebookDocumentOutput(path: "figure.png", format: "image"), count: 28)
        let quizzes = Array(repeating: NotebookDocumentOutput(path: "test.quiz.json", format: "quiz"), count: 6)
        let response = NotebookAssistantResponse(reply: "", edits: Array(repeating: .init(path: "Note.md", replacement: "Rewrite"), count: 6), outputs: images + quizzes)
        XCTAssertEqual(try NotebookAssistantProtocol.decode(json(response)).outputs?.count, 34)
        let error = NotebookResponseValidationError(code: "outputs_with_reads", actual: nil, limit: nil, fields: "outputs + readFiles")
        let diagnostic = NotebookResponseDiagnostic(text: try json(response), error: error, provider: .claudeCode, notebookID: "invented", requestID: "request", attempt: 1)
        XCTAssertEqual(diagnostic.outputs, 34); XCTAssertEqual(diagnostic.edits, 6)
        if let path = ProcessInfo.processInfo.environment["NOTES_NOTEBOOK_RESPONSE_EVIDENCE"] {
            let captured = try String(contentsOfFile: path, encoding: .utf8)
            let decoded = try NotebookAssistantProtocol.decode(captured)
            XCTAssertEqual(decoded.outputs?.count, 34)
            XCTAssertEqual(decoded.edits.count, 6)
            for output in decoded.outputs ?? [] { try output.test?.validate() }
        }
    }

    func testPrivateBoundedMetadataWithoutResponseContents() throws {
        let workspace = try workspace(), log = NotebookResponseDiagnostics(workspace: workspace)
        let response = NotebookAssistantResponse(reply: "PRIVATE SOURCE AND SECRET", readFiles: ["private-file.md"], edits: [.init(path: "private-file.md", replacement: "PRIVATE REPLACEMENT")])
        let text = try json(response), error = try failure(response)
        for attempt in 1...105 {
            try log.append(.init(text: text, error: error, provider: .claudeCode, notebookID: "notebook", requestID: "request", attempt: attempt))
        }
        let data = try workspace.readStorage(NotebookResponseDiagnostics.path)
        XCTAssertLessThanOrEqual(data.count, NotebookResponseDiagnostics.maximumBytes)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        let records = try decoder.decode([NotebookResponseDiagnostic].self, from: data)
        XCTAssertEqual(records.count, 100); XCTAssertEqual(records.first?.attempt, 6); XCTAssertEqual(records.last?.attempt, 105)
        XCTAssertEqual(records.last?.code, "reads_with_edits"); XCTAssertEqual(records.last?.edits, 1)
        XCTAssertEqual(records.last?.responseBytes, text.utf8.count); XCTAssertEqual(records.last?.responseSHA256.count, 64)
        let stored = String(decoding: data, as: UTF8.self)
        for privateValue in ["PRIVATE SOURCE", "PRIVATE REPLACEMENT", "private-file.md"] { XCTAssertFalse(stored.contains(privateValue)) }
        let file = workspace.storageRoot.appendingPathComponent(NotebookResponseDiagnostics.path)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)[.posixPermissions] as? Int, 0o700)
    }

    func testDecodingPathAndSymlinkRefusal() throws {
        let workspace = try workspace()
        let text = #"{"reply":5,"readFiles":[],"edits":[]}"#
        do { _ = try NotebookAssistantProtocol.decode(text); XCTFail("Expected decoding error") }
        catch {
            let record = NotebookResponseDiagnostic(text: text, error: error, provider: .claudeCode, notebookID: "n", requestID: "r", attempt: 1)
            XCTAssertEqual(record.code, "invalid_json"); XCTAssertEqual(record.decodingPath, "reply")
            let outside = workspace.root.appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: workspace.storageRoot, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: workspace.storageRoot.appendingPathComponent("diagnostics"), withDestinationURL: outside)
            XCTAssertThrowsError(try NotebookResponseDiagnostics(workspace: workspace).append(record))
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        }
    }

    func testSchemaDoesNotCapActionCounts() {
        let properties = NotebookAssistantProtocol.schema["properties"] as? [String: Any]
        for field in ["outputs", "edits", "readFiles", "webActions"] {
            XCTAssertNil((properties?[field] as? [String: Any])?["maxItems"])
        }
    }

    func testByteRetentionAndRecoveryFromDamagedLog() throws {
        let workspace = try workspace(), log = NotebookResponseDiagnostics(workspace: workspace)
        let text = try json(.init(reply: "", readFiles: Array(repeating: "note", count: 31)))
        let error = NotebookResponseValidationError(code: "read_files_count", actual: 31, limit: 30, fields: "readFiles count")
        let record = NotebookResponseDiagnostic(text: text, error: error, provider: .claudeCode, notebookID: String(repeating: "n", count: 8_000), requestID: "r", attempt: 1)
        for _ in 1...30 { try log.append(record) }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        var data = try workspace.readStorage(NotebookResponseDiagnostics.path)
        XCTAssertLessThanOrEqual(data.count, NotebookResponseDiagnostics.maximumBytes)
        XCTAssertLessThan(try decoder.decode([NotebookResponseDiagnostic].self, from: data).count, 30)
        for damaged in [Data("broken".utf8), Data(repeating: 120, count: NotebookResponseDiagnostics.maximumBytes + 1)] {
            try workspace.writeStorage(NotebookResponseDiagnostics.path, data: damaged)
            try log.append(record)
            data = try workspace.readStorage(NotebookResponseDiagnostics.path)
            XCTAssertEqual(try decoder.decode([NotebookResponseDiagnostic].self, from: data).count, 1)
        }
    }

    func testRejectedSemanticResponseRetriesOnceWithSpecificReason() async throws {
        try await retry(alwaysReject: false)
    }

    func testRepeatedRejectionIncludesSavedDiagnosticID() async throws {
        try await retry(alwaysReject: true)
    }

    func testDiagnosticStorageFailureDoesNotMaskValidationFailure() async throws {
        try await retry(alwaysReject: true, blockedDiagnostics: true)
    }

    func testJSONTypeFailureRetriesWithExactFieldPath() async throws {
        try await retry(alwaysReject: false, invalidJSONType: true)
    }

    private func retry(alwaysReject: Bool, blockedDiagnostics: Bool = false, invalidJSONType: Bool = false) async throws {
        let workspace = try workspace()
        if blockedDiagnostics {
            let outside = workspace.root.appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: workspace.storageRoot, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: workspace.storageRoot.appendingPathComponent("diagnostics"), withDestinationURL: outside)
        }
        let script = workspace.root.appendingPathComponent("mock-claude")
        let executable = """
        #!/usr/bin/env python3
        import json, pathlib, sys
        root = pathlib.Path(\(String(reflecting: workspace.root.path)))
        count_file = root / 'attempts'
        attempt = int(count_file.read_text()) + 1 if count_file.exists() else 1
        count_file.write_text(str(attempt))
        prompt = sys.stdin.read()
        if attempt == 2:
            assert \(String(reflecting: invalidJSONType ? "invalid JSON at reply" : "outputs + readFiles cannot be combined in one response")) in prompt
            assert 'rejected before applying any edits' in prompt
        output = {'reply':'PRIVATE TEXT', 'readFiles':[], 'edits':[], 'webActions':[], 'outputs':[]}
        if attempt == 1 or \(alwaysReject ? "True" : "False"):
            if \(invalidJSONType ? "True" : "False"):
                output['reply'] = 5
            else:
                output['outputs'] = [{'path':'figure.png','sourcePath':'private-source.pdf','format':'image','source':''}] * 11
                output['readFiles'] = ['Note.md']
        print(json.dumps({'type':'system','subtype':'init','tools':['StructuredOutput'],'mcp_servers':[]}))
        print(json.dumps({'type':'result','subtype':'success','is_error':False,'structured_output':output}))
        """
        try executable.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        var configuration = AIProviderConfiguration(provider: .claudeCode, executablePath: script.path, model: "claude-sonnet-5-5")
        configuration.accountSendingAllowed = true
        let request = NotebookTextRequest(notebook: Notebook(id: "invented", name: "Invented", rootPrefix: ""), profile: NotebookProfile(), messages: [.init(role: "user", text: "Invented private prompt")], currentDocument: nil, texts: [:], language: "en")
        var failure: String?
        do {
            let response = try await NotesProviderTransport(store: LocalMediaStore(workspace: workspace)).sendNotebook(request, configuration: configuration)
            XCTAssertFalse(alwaysReject); XCTAssertEqual(response.reply, "PRIVATE TEXT")
        } catch {
            XCTAssertTrue(alwaysReject); failure = error.localizedDescription
            XCTAssertTrue(failure?.contains("outputs + readFiles cannot be combined in one response") == true)
        }
        XCTAssertEqual(try String(contentsOf: workspace.root.appendingPathComponent("attempts"), encoding: .utf8), "2")
        XCTAssertTrue(try workspace.noteNames().isEmpty)
        if blockedDiagnostics {
            XCTAssertTrue(failure?.contains("Local diagnostic could not be saved") == true)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: workspace.root.appendingPathComponent("outside").path).isEmpty)
            return
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .secondsSince1970
        let records = try decoder.decode([NotebookResponseDiagnostic].self, from: workspace.readStorage(NotebookResponseDiagnostics.path))
        XCTAssertEqual(records.count, alwaysReject ? 2 : 1)
        XCTAssertEqual(records.first?.code, invalidJSONType ? "invalid_json" : "outputs_with_reads")
        XCTAssertEqual(records.first?.outputs, invalidJSONType ? nil : 11)
        if invalidJSONType { XCTAssertEqual(records.first?.decodingPath, "reply") }
        if alwaysReject {
            XCTAssertEqual(records.first?.requestID, records.last?.requestID)
            XCTAssertEqual(records.last?.attempt, 2)
            XCTAssertTrue(failure?.contains(try XCTUnwrap(records.last?.id)) == true)
        }
    }
}
