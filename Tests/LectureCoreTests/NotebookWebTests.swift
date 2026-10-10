import XCTest
@testable import LectureCore

final class NotebookWebTests: XCTestCase {
    func testPublicURLValidationAndPageExtraction() throws {
        for url in ["file:///tmp/private", "http://example.com", "https://localhost", "https://127.0.0.1", "https://10.1.2.3", "https://172.16.1.2", "https://192.168.1.2", "https://user:password@example.com", "https://example.com:8080"] { XCTAssertThrowsError(try NotebookWebClient.validateURL(url), url) }
        XCTAssertNoThrow(try NotebookWebClient.validateURL("https://example.com/image.gif"))
        let html = #"<script>private script</script><h1>Public &amp; readable</h1><img src="/image.gif"><meta content="https://example.com/a.png">"#
        XCTAssertEqual(NotebookWebClient.pageText(html).trimmingCharacters(in: .whitespaces), "Public & readable")
        XCTAssertEqual(NotebookWebClient.imageURLs(html, base: URL(string: "https://example.com/page")!), ["https://example.com/image.gif", "https://example.com/a.png"])
    }
    func testWebProtocolDoesNotMixWebActionsWithEditsAndBlocksNativeSearchWhenOff() throws {
        let valid = #"{"reply":"","readFiles":[],"edits":[],"webActions":[{"kind":"search","query":"public query","url":""}]}"#
        XCTAssertEqual(try NotebookAssistantProtocol.decode(valid).webActions?.first?.kind, "search")
        let mixed = valid.replacingOccurrences(of: #""readFiles":[]"#, with: #""readFiles":["Test.md"]"#)
        XCTAssertThrowsError(try NotebookAssistantProtocol.decode(mixed))
        var decoder = CodexNotebookProgressDecoder(threadID: "t", webEnabled: true)
        _ = try decoder.accept("turn/started", ["threadId": "t", "turn": ["id": "turn"]])
        let event: [String: Any] = ["threadId": "t", "turnId": "turn", "item": ["type": "webSearch", "id": "search", "action": ["query": "public query"]]]
        XCTAssertEqual(try decoder.accept("item/started", event)?.detail, "public query")
        decoder.webEnabled = false
        XCTAssertThrowsError(try decoder.accept("item/started", event))
        XCTAssertTrue(NotebookAssistantProtocol.webInstructions(enabled: false, native: true).contains("OFF"))
    }
    func testImageDownloadValidatesBytesAndKeepsAssetInsideNotebook() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".test-workspaces/WebAsset-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("copied-course"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try SafeWorkspace(root: root, originalRoot: root.appendingPathComponent("original"))
        let gif = Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")!
        let client = NotebookWebClient(fetch: { url in (gif, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [:])!) })
        let action = NotebookWebAction(kind: "downloadImage", url: "https://example.com/picture.gif")
        let result = try await client.execute(action, workspaceRoot: root, originalRoot: workspace.originalRoot, notebook: Notebook(name: "Demo", rootPrefix: "Demo"))
        let path = try XCTUnwrap(result.localImagePath)
        XCTAssertTrue(path.hasPrefix("Demo/.palladium-images/")); XCTAssertTrue(path.hasSuffix(".gif"))
        XCTAssertEqual(try Data(contentsOf: workspace.fileURL(path)), gif)
        let repeated = try await client.execute(action, workspaceRoot: root, originalRoot: workspace.originalRoot, notebook: Notebook(name: "Demo", rootPrefix: "Demo"))
        XCTAssertEqual(repeated.localImagePath, path)
        let invalid = NotebookWebClient(fetch: { url in (Data("<html>Not an image</html>".utf8), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [:])!) })
        do { _ = try await invalid.execute(action, workspaceRoot: root, originalRoot: workspace.originalRoot, notebook: Notebook(name: "Demo", rootPrefix: "Demo")); XCTFail("Invalid image must not be saved") } catch { }
    }
    func testLiveConfiguredProviderWebRoundTrip() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let provider = env["NOTES_LIVE_WEB_PROVIDER"], let settingsPath = env["NOTES_LIVE_WEB_SETTINGS"] else { throw XCTSkip("Live provider web test is opt-in") }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".test-workspaces/Web-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("copied-course"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try SafeWorkspace(root: root, originalRoot: root.appendingPathComponent("original"))
        let settings = try JSONDecoder().decode(AIProviderSettings.self, from: Data(contentsOf: URL(fileURLWithPath: settingsPath)))
        let configuration = provider == "codex" ? settings.codexCLI : provider == "antigravity" ? settings.antigravity : settings.openCode
        let notebook = Notebook(name: "Demo", rootPrefix: "")
        let prompt = env["NOTES_LIVE_WEB_PROMPT"] ?? "Search the web for Apple's latest iPhone announcement. Create iPhone.md with a short English summary and source links. Verify the date."
        var request = NotebookTextRequest(notebook: notebook, profile: .init(), messages: [.init(role: "user", text: prompt)], currentDocument: nil, texts: [:], language: "en")
        request.nativeWebSearch = provider == "codex"
        var count = 0
        for _ in 0..<10 {
            let response = try await NotesProviderTransport(store: LocalMediaStore(workspace: workspace)).sendNotebook(request, configuration: configuration)
            if let actions = response.webActions, !actions.isEmpty {
                for action in actions {
                    print("WEB_ACTION provider=\(provider) kind=\(action.kind)")
                    do { request.webResults.append(try await NotebookWebClient().execute(action, workspaceRoot: root, originalRoot: workspace.originalRoot, notebook: notebook)); count += 1 }
                    catch { request.webResults.append(.init(action: action, source: action.url, text: "", error: error.localizedDescription)); print("WEB_ACTION_FAILED \(error.localizedDescription)") }
                }
                request.contextUpdate = "Continue with new webResults."
            } else {
                XCTAssertFalse(response.edits.isEmpty, response.reply)
                XCTAssertTrue(response.edits.contains { $0.replacement.contains("https://") }, response.reply)
                print("WEB_RESULT provider=\(provider) actions=\(count) edits=\(response.edits.count) reply=\(response.reply.prefix(300))")
                if env["NOTES_LIVE_WEB_PROMPT"] != nil { XCTAssertTrue(request.webResults.contains { $0.localImagePath != nil }, "Image must be downloaded locally") }
                return
            }
        }
        XCTFail("Provider did not complete the web request")
    }
}
