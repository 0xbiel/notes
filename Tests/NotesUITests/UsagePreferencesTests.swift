import XCTest
import SwiftUI
import LectureCore
@testable import Notes

final class UsagePreferencesTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @MainActor private func render(_ view: some View, size: NSSize, dark: Bool, name: String) async throws -> NSBitmapImageRep {
        let output = root.appendingPathComponent("qa/usage")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let host = NSHostingView(rootView: view.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, dark ? .dark : .light))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(400))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + (dark ? "-dark" : "-light") + ".png"))
        window.close()
        return bitmap
    }

    func testCountdownShowsTheTwoLargestUnits() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(UsageFormat.countdown(to: now.addingTimeInterval(22 * 60), now: now), "22m")
        XCTAssertEqual(UsageFormat.countdown(to: now.addingTimeInterval(4 * 3_600 + 58 * 60), now: now), "4h 58m")
        XCTAssertEqual(UsageFormat.countdown(to: now.addingTimeInterval(3 * 86_400 + 4 * 3_600 + 10), now: now), "3d 4h")
        XCTAssertEqual(UsageFormat.countdown(to: now.addingTimeInterval(-60), now: now), "0m")
    }

    @MainActor func testUsageHistoryAndLimitsRender() async throws {
        _ = NSApplication.shared
        let folder = root.appendingPathComponent(".test-workspaces/UsageView-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("copied-course"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let workspace = try SafeWorkspace(root: folder, originalRoot: folder.appendingPathComponent("original"))
        let now = Date(), day = 86_400.0
        try ProviderUsageLog(workspace: workspace).append((0..<24).flatMap { index -> [ProviderUsageRecord] in
            let date = now.addingTimeInterval(-Double(index) * day - 60)
            return [.init(date: date, provider: .codexCLI, notebookID: "n", usage: .init(model: "gpt-6.1-sol", input: 40_000 * (index % 5 + 1), cachedInput: 600_000, output: 9_000)),
                    .init(date: date, provider: .claudeCode, notebookID: "n", usage: .init(model: "claude-sonnet-5-5", input: 30_000, cachedInput: 200_000 * (index % 3), output: 12_000)),
                    .init(date: date, provider: .antigravity, notebookID: "n", usage: .init(model: "gemini-3.5-flash", input: 90_000, output: 4_000 * (index % 4)))]
        })
        let defaults = UserDefaults.standard, saved = ["notes.usageMetric", "notes.usagePeriod", "notes.language"].map { ($0, defaults.string(forKey: $0)) }
        addTeardownBlock { saved.forEach { defaults.set($0.1, forKey: $0.0) } }
        defaults.set("en", forKey: "notes.language"); defaults.set("30", forKey: "notes.usagePeriod")
        let limits: @Sendable (AIProviderConfiguration, LocalMediaStore) async -> ProviderLimits = { configuration, _ in
            var value = ProviderLimits(provider: configuration.provider, name: configuration.name)
            switch configuration.provider {
            case .claudeCode:
                value.plan = "pro"
                value.windows = [.init(id: "five_hour", kind: .session, usedPercent: 28, resetsAt: Date().addingTimeInterval(22 * 60)), .init(id: "seven_day", kind: .weekly, usedPercent: 23, resetsAt: Date().addingTimeInterval(3 * day + 4 * 3_600))]
            case .antigravity:
                value.windows = [.init(id: "gemini-5h", kind: .session, scope: "Gemini", usedPercent: 0, resetsAt: Date().addingTimeInterval(5 * 3_600)), .init(id: "3p-weekly", kind: .weekly, scope: "Claude & GPT", usedPercent: 97, resetsAt: Date().addingTimeInterval(6 * day))]
            default: value.message = "Este proveedor no publica límites para esta cuenta."
            }
            return value
        }
        for dark in [false, true] {
            for metric in ["cost", "tokens"] {
                defaults.set(metric, forKey: "notes.usageMetric")
                let bitmap = try await render(UsagePreferences(workspace: workspace, hovered: metric == "cost" ? now.addingTimeInterval(-9 * day) : nil), size: NSSize(width: 720, height: 1_000), dark: dark, name: metric)
                XCTAssertGreaterThan(bitmap.pixelsWide, 0)
            }
            defaults.set("limits", forKey: "notes.usageMetric")
            _ = try await render(UsagePreferences(workspace: workspace, readLimits: limits), size: NSSize(width: 720, height: 760), dark: dark, name: "limits")
        }
    }

    @MainActor func testWorkLogShowsThoughtsWhileRunningAndTitlesThem() async throws {
        _ = NSApplication.shared
        func activity(_ id: String, _ title: String, detail: String? = nil, kind: NotebookActivityKind = .status) -> NotebookActivity {
            var value = NotebookActivity(title)
            value.id = id; value.detail = detail; value.kind = kind
            return value
        }
        let activities = [
            activity("read", "Leyendo el cuaderno…"),
            activity("file", "Leyendo · Tema 3.md", detail: "Tema 3.md", kind: .tool),
            activity("t1", "Pensando…", detail: "**Evaluating testing needs**\n\nThe request does not name exact tests, so the checks must validate the centre and examine the real source geometry.", kind: .reasoning),
            activity("web", "Buscando en la web…", detail: "contract formation consideration", kind: .tool),
            activity("t2", "Pensando…", detail: "**Optimizing panel preview**\n\nThe panel preview should show a neat snapshot rather than a huge empty one. Cropping keeps the evidence readable.", kind: .reasoning)
        ]
        let view = VStack(alignment: .leading, spacing: 24) {
            NotebookWorkLog(activities: activities, running: true)
            NotebookWorkLog(activities: activities)
        }.frame(width: 640)
        for dark in [false, true] { _ = try await render(view, size: NSSize(width: 700, height: 420), dark: dark, name: "worklog") }
    }
}
