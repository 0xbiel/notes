import XCTest
@testable import LectureCore

final class NotebookNativeSessionTests: XCTestCase {
    func testPersistentDeltaIsolationAndLease() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".test-workspaces/native-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("copied-course"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalMediaStore(workspace: try SafeWorkspace(root: root, originalRoot: root.appendingPathComponent("original")))
        let configuration = AIProviderConfiguration(provider: .claudeCode, executablePath: "/test/claude")
        func session(_ chat: String = "one", web: Bool = false) throws -> NotebookNativeSession {
            try .init(store: store, notebookID: "notebook", chatID: chat, configuration: configuration, webEnabled: web, language: "en")
        }
        let first = try session()
        var lease: NotebookNativeSessionLease? = try .init(first)
        XCTAssertThrowsError(try NotebookNativeSessionLease(first))
        withExtendedLifetime(lease) {}
        lease = nil
        let secondLease = try NotebookNativeSessionLease(first)
        defer { withExtendedLifetime(secondLease) {} }
        var request = NotebookTextRequest(notebook: .copiedCourse, profile: .init(), messages: [.init(role: "user", text: "FIRST_MESSAGE")], currentDocument: nil, texts: [:])
        request.documents = ["test.md": "ORIGINAL_SOURCE"]
        let initial = try first.prompt(request, images: [], correction: "")
        XCTAssertTrue(initial.0.contains("FIRST_MESSAGE"))
        var record = NotebookNativeSession.Record()
        record.nativeID = UUID().uuidString; record.initialized = true; record.snapshot = initial.1
        try first.save(record)
        request.messages.append(.init(role: "user", text: "NEW_MESSAGE"))
        let resumed = try session()
        XCTAssertEqual(try resumed.load().nativeID, record.nativeID)
        let delta = try resumed.prompt(request, images: [], correction: "").0
        XCTAssertFalse(delta.contains("FIRST_MESSAGE")); XCTAssertFalse(delta.contains("ORIGINAL_SOURCE"))
        XCTAssertTrue(delta.contains("NEW_MESSAGE"))
        request.documents = ["test.md": "UPDATED_SOURCE"]
        XCTAssertTrue(try resumed.prompt(request, images: [], correction: "").0.contains("UPDATED_SOURCE"))
        request.documents = [:]
        XCTAssertTrue(try resumed.prompt(request, images: [], correction: "").0.contains("\"removedDocuments\":[\"test.md\"]"))
        XCTAssertFalse(try session("two").load().initialized)
        XCTAssertFalse(try session(web: true).load().initialized)
    }

    func testCodexRPCStartResumeAndNativeCompact() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".test-workspaces/native-rpc-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("copied-course"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("codex.py")
        try """
        #!/usr/bin/python3
        import sys,json,os
        def emit(v): print(json.dumps(v),flush=True)
        def event(method,params): emit({'method':method,'params':dict(threadId='native-test',**params)})
        for line in sys.stdin:
            msg=json.loads(line); method=msg['method']; params=msg.get('params',{})
            if 'id' not in msg: continue
            result={}
            if method=='thread/start':
                assert params['ephemeral'] is False
                assert not os.path.exists('started')
                open('started','w').close()
                result={'thread':{'id':'native-test'}}
            if method=='thread/resume':
                assert params['threadId']=='native-test' and os.path.exists('started')
                result={'thread':{'id':'native-test'}}
            emit({'id':msg['id'],'result':result})
            if method in ['turn/start','thread/compact/start']:
                event('turn/started',{'turn':{'id':'turn'}})
                if method=='thread/compact/start':
                    event('item/completed',{'item':{'type':'contextCompaction'}})
                else:
                    event('item/completed',{'item':{'type':'agentMessage','text':'{"reply":"done","readFiles":[],"edits":[]}'}})
                event('thread/tokenUsage/updated',{'tokenUsage':{'last':{'totalTokens':100},'modelContextWindow':1000}})
                event('turn/completed',{'turn':{'id':'turn','status':'completed'}})
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let config = AIProviderConfiguration(provider: .codexCLI, executablePath: script.path, homePath: root.appendingPathComponent("empty-account").path)
        let store = LocalMediaStore(workspace: try SafeWorkspace(root: root, originalRoot: root.appendingPathComponent("original")))
        let session = try NotebookNativeSession(store: store, notebookID: "n", chatID: "c", configuration: config, webEnabled: false, language: "en")
        try session.prepare()
        let transport = CodexNotebookStreamingTransport(store: store, configuration: config)
        for _ in 0..<2 {
            let reply = try await transport.generate("hello", language: "en", images: [], progress: { _ in }, session: session)
            XCTAssertTrue(reply.contains("done"))
        }
        let oldUser = NotebookMessage(role: "user", text: "OLD_USER_REQUIREMENT")
        let receipt = NotebookMessage(role: "assistant", text: "OLD_VERBOSE_RECEIPT_" + String(repeating: "details ", count: 2000))
        try await NotesProviderTransport(store: store).compactNotebook(notebookID: "n", chatID: "c", configuration: config, webEnabled: false, language: "en", messages: [oldUser, receipt], progress: { _ in })
        var next = NotebookTextRequest(notebook: .copiedCourse, profile: .init(), messages: [oldUser, receipt], currentDocument: nil, texts: [:])
        next.messages.append(.init(role: "user", text: "CONTINUE_AFTER_COMPACTION"))
        let delta = try session.prompt(next, images: [], correction: "").0
        XCTAssertFalse(delta.contains("OLD_USER_REQUIREMENT"))
        XCTAssertFalse(delta.contains("OLD_VERBOSE_RECEIPT"))
        XCTAssertTrue(delta.contains("CONTINUE_AFTER_COMPACTION"))
        XCTAssertEqual(try session.load().context?.usedTokens, 100)
        XCTAssertEqual(try session.load().context?.compacted, true)
    }

    func testNativeBootstrapIncludesFullHistoryRatherThanBudgetProjection() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".test-workspaces/native-full-history-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("copied-course"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalMediaStore(workspace: try SafeWorkspace(root: root, originalRoot: root.appendingPathComponent("original")))
        let config = AIProviderConfiguration(provider: .claudeCode, executablePath: "/test/claude")
        let session = try NotebookNativeSession(store: store, notebookID: "n", chatID: "c", configuration: config, webEnabled: false, language: "en")
        let messages = (0..<60).map { NotebookMessage(role: $0.isMultiple(of: 2) ? "user" : "assistant", text: "HISTORY_\($0)_" + String(repeating: "content ", count: 200)) }
        let request = NotebookTextRequest(notebook: .copiedCourse, profile: .init(), messages: messages, currentDocument: nil, texts: [:])
        let prompt = try session.prompt(request, images: [], correction: "").0
        for message in messages { XCTAssertTrue(prompt.contains(message.text)) }
        XCTAssertGreaterThan(prompt.utf8.count, NotebookConversationContext.byteBudget)
    }

    func testNativeArgumentsAndContextEvents() throws {
        let id = UUID().uuidString
        let config = AIProviderConfiguration(provider: .claudeCode, executablePath: "/test/claude")
        let args = try ClaudeTextTransport.arguments(config, schema: [:], instructions: "", sessionID: id, resume: true, compact: true)
        XCTAssertTrue(args.contains("--resume")); XCTAssertFalse(args.contains("--no-session-persistence")); XCTAssertFalse(args.contains("--json-schema"))
        var claude = ClaudeStreamDecoder(compact: true)
        let event = try JSONSerialization.data(withJSONObject: ["type": "system", "subtype": "compact_boundary", "compact_metadata": ["post_tokens": 1234]])
        XCTAssertEqual(try claude.accept(event)?.context?.usedTokens, 1234)
        XCTAssertTrue(claude.didCompact)
        var codex = CodexNotebookProgressDecoder(threadID: "t", compact: true)
        let usage: [String: Any] = ["threadId": "t", "tokenUsage": ["last": ["totalTokens": 200, "inputTokens": 180, "outputTokens": 20], "total": ["totalTokens": 9000], "modelContextWindow": 1000]]
        XCTAssertEqual(try codex.accept("thread/tokenUsage/updated", usage)?.context?.usedTokens, 200)
        XCTAssertFalse(codex.reportedPostCompactContext)
        _ = try codex.accept("item/completed", ["threadId": "t", "item": ["type": "contextCompaction"]])
        XCTAssertTrue(codex.didCompact)
        XCTAssertEqual(try codex.accept("thread/tokenUsage/updated", usage)?.context?.compacted, true)
        XCTAssertTrue(codex.reportedPostCompactContext)
    }
}
