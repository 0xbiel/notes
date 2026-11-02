import XCTest
import SwiftUI
import WebKit
import LectureCore
@testable import Notes

final class NotebookCustomUITests: XCTestCase {
    @MainActor private func evaluate(_ script: String, in view: WKWebView) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            view.evaluateJavaScript(script) { result, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: result as? String ?? "") }
            }
        }
    }
    @MainActor private func reportCount(_ count: Int, view: WKWebView) async throws -> [[String: Any]] {
        for _ in 0..<200 {
            let json = try await evaluate("JSON.stringify(window.reports || [])", in: view)
            if let data = json.data(using: .utf8), let reports = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], reports.count >= count { return reports }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("The embedded HTML did not report its rendered state")
        return []
    }
    @MainActor func testEmbeddedJavaScriptThemeSwitchAndOpaqueOrigin() async throws {
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(.init(source: "window.reports=[];window.addEventListener('message',e=>{if(e.data?.report)window.reports.push(e.data)})", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 700, height: 600), configuration: configuration)
        let coordinator = NotebookHTMLSurface.Coordinator()
        view.navigationDelegate = coordinator
        let light = NotebookHTMLSurface.theme(dark: false, accent: .orange, bottomInset: 80)
        let dark = NotebookHTMLSurface.theme(dark: true, accent: .purple, bottomInset: 160)
        XCTAssertNotEqual(light["--notebook-background"], dark["--notebook-background"])
        let source = """
        <h1>Journal</h1><input id="amount" value="7"><button id="add" onclick="document.getElementById('amount').value='42'">Add</button>
        <script>
        function report(){
          let isolated=false;try{parent.document.body}catch(e){isolated=true}
          parent.postMessage({report:true,mode:document.documentElement.dataset.theme,
            value:document.getElementById('amount').value,isolated,
            background:getComputedStyle(document.body).backgroundColor,
            accent:getComputedStyle(document.documentElement).getPropertyValue('--notebook-accent'),
            inset:getComputedStyle(document.documentElement).getPropertyValue('--notebook-bottom-inset')},'*');
        }
        window.addEventListener('DOMContentLoaded',report);
        window.addEventListener('palladium-theme-change',report);
        window.addEventListener('message',e=>{if(e.data==='click'){document.getElementById('add').click();report()}});
        </script>
        """
        coordinator.theme = light
        view.loadHTMLString(NotebookCustomUI.document(source: source, theme: light), baseURL: nil)
        defer { view.stopLoading(); view.navigationDelegate = nil }
        let initial = try await reportCount(1, view: view)
        XCTAssertEqual(initial.first?["mode"] as? String, "light")
        XCTAssertEqual(initial.first?["isolated"] as? Bool, true)
        XCTAssertEqual(initial.first?["value"] as? String, "7")
        // didFinish can send a second initial theme report; establish the count now.
        let clicked = try await evaluate("document.querySelector('iframe').contentWindow.postMessage('click','*'); 'sent'", in: view)
        XCTAssertEqual(clicked, "sent")
        var reports = try await reportCount(initial.count + 1, view: view)
        if reports.last?["value"] as? String != "42" { reports = try await reportCount(reports.count + 1, view: view) }
        XCTAssertEqual(reports.last?["value"] as? String, "42")
        coordinator.theme = dark; coordinator.updateTheme(view)
        let updated = try await reportCount(reports.count + 1, view: view)
        XCTAssertEqual(updated.last?["mode"] as? String, "dark")
        XCTAssertEqual(updated.last?["value"] as? String, "42", "Appearance changes must preserve entered values")
        XCTAssertEqual(updated.last?["inset"] as? String, dark["--notebook-bottom-inset"])
        XCTAssertNotEqual(initial.first?["background"] as? String, updated.last?["background"] as? String)
        XCTAssertEqual(updated.last?["accent"] as? String, dark["--notebook-accent"])
    }
    @MainActor func testHTMLOutputsStayInNotebookAndRefuseOverwrite() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".test-workspaces/HTMLOutput-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("copied-course"), withIntermediateDirectories: true)
        let workspace = try SafeWorkspace(root: root, originalRoot: root.appendingPathComponent("original"))
        let notebook = Notebook(id: "accounting", name: "Accounting", rootPrefix: "Accounting")
        let store = try NotebookProjectStore(workspace: workspace, notebooks: [.copiedCourse, notebook])
        let output = NotebookDocumentOutput(path: "Accounting/Entries.ui.html", format: "html", source: "<h1>Entries</h1>")
        let prepared = try NotebookDocumentOutputWriter.prepare([output], documents: [:], changes: [], store: store, notebook: notebook)
        try NotebookDocumentOutputWriter.publish(prepared, workspace: workspace)
        XCTAssertEqual(try workspace.readNote(output.path), output.source)
        XCTAssertThrowsError(try NotebookDocumentOutputWriter.prepare([output], documents: [:], changes: [], store: store, notebook: notebook))
        for path in ["Outside.ui.html", "Accounting/../Outside.ui.html", "Accounting/view.html"] {
            var invalid = output; invalid.path = path
            XCTAssertThrowsError(try NotebookDocumentOutputWriter.prepare([invalid], documents: [:], changes: [], store: store, notebook: notebook))
        }
        try NotebookDocumentOutputWriter.rollback(prepared, workspace: workspace)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try workspace.fileURL(output.path).path))
    }
}
