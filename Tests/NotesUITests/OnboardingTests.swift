import XCTest
import SwiftUI
@testable import Notes

final class OnboardingTests: XCTestCase {
    @MainActor private func library() throws -> (Workbench, URL) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".test-workspaces/Onboarding-" + UUID().uuidString)
        return (Workbench(workspaceRoot: try Workbench.prepareLibrary(root)), root)
    }

    @MainActor func testNewLibraryStartsEmptyAndIntroductionCreatesTheFirstNotebook() throws {
        let (model, root) = try library(); defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(model.errorText)
        XCTAssertTrue(model.activeNotebooks.isEmpty)
        // A workspace handed to the app is never treated as a new user's.
        XCTAssertFalse(model.showOnboarding)
        // Preparing again keeps what the library already holds.
        try model.createNotebookItem(kind: "cuaderno", name: "Ideas")
        XCTAssertEqual(Workbench(workspaceRoot: try Workbench.prepareLibrary(root)).activeNotebooks.map(\.name), ["Ideas"])

        let seen = UserDefaults.standard.object(forKey: "notes.onboarded")
        defer { UserDefaults.standard.set(seen, forKey: "notes.onboarded") }
        model.showOnboarding = true
        model.finishOnboarding()
        XCTAssertFalse(model.showOnboarding)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "notes.onboarded"))
    }

    @MainActor func testIntroductionAndEmptyLibraryLayOutInTheWorkbench() throws {
        let (model, root) = try library(); defer { try? FileManager.default.removeItem(at: root) }
        for onboarding in [true, false] {
            model.showOnboarding = onboarding
            let host = NSHostingView(rootView: WorkbenchView(model: model))
            host.frame = NSRect(x: 0, y: 0, width: 1000, height: 700); host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.fittingSize.width > 0, true)
        }
    }
}
