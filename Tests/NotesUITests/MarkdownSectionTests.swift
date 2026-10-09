import XCTest
import AppKit
import SwiftUI
@testable import Notes

final class MarkdownSectionTests: XCTestCase {
    @MainActor func testAllVisibleSectionsIncludePartlyVisibleBodies() {
        let state = MarkdownSectionState()
        state.sections = MarkdownSection.parse("# One\n# Two\n# Three")
        let ids = state.sections.map(\.id)
        state.visibleIDs = MarkdownSectionNavigation.visibleIDs(sections: state.sections, positions: [0, 100, 200],
            documentHeight: 400, viewport: CGRect(x: 0, y: 50, width: 300, height: 200))
        XCTAssertEqual(state.visibleIDs, Set(ids))
        XCTAssertEqual(state.overviewVisibleIDs, Set(ids))
        XCTAssertEqual(MarkdownSectionNavigation.visibleIDs(sections: state.sections, positions: [0, 100, 200],
            documentHeight: 400, viewport: CGRect(x: 0, y: 100, width: 300, height: 100)), [ids[1]])
    }

    func testHoverTooltipStaysInsideBothRailEdges() {
        XCTAssertEqual(MarkdownSectionTooltip.center(rowY: 5, height: 80, availableHeight: 280), 40)
        XCTAssertEqual(MarkdownSectionTooltip.center(rowY: 275, height: 80, availableHeight: 280), 240)
        XCTAssertEqual(MarkdownSectionTooltip.center(rowY: 140, height: 80, availableHeight: 280), 140)
        XCTAssertEqual(MarkdownSectionTooltip.center(rowY: 100, height: 100, availableHeight: 112), 62)
    }

    @MainActor func testFirstAndLastHoverLabelsRenderWithoutScrollClipping() async throws {
        _ = NSApplication.shared
        let state = MarkdownSectionState()
        state.sections = MarkdownSection.parse("# Long notebook heading for hover label ancestors\n" + (1...18).map { "## Section \($0) with a deliberately long title that wraps across multiple lines" }.joined(separator: "\n"))
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("qa/section-hover")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for section in [state.sections.first!, state.sections.last!] {
            let host = NSHostingView(rootView: MarkdownSectionIndicator(state: state, initialHoveredID: section.id).environment(\.colorScheme, .dark))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 280, height: 280), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host; host.frame = NSRect(x: 0, y: 0, width: 280, height: 280)
            host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(section == state.sections.first ? "first.png" : "last.png"))
            window.close()
        }
    }

    func testHeadingSectionsIgnoreCodeAndKeepDuplicateHeadingsDistinct() {
        let source = "# **Overview**\n\n😀\n## Details ###\n```md\n# Not a section\n```\n~~~\n## Also code\n~~~\n    # Indented code\n\\# Escaped\n####### Too many\n#No space\n## Details\n###### Deep\n"
        let sections = MarkdownSection.parse(source)
        XCTAssertEqual(sections.map(\.title), ["Overview", "Details", "Details", "Deep"])
        XCTAssertEqual(sections.map(\.level), [1, 2, 2, 6])
        XCTAssertEqual(Set(sections.map(\.id)).count, 4)
        XCTAssertEqual((source as NSString).substring(with: sections[1].range), "## Details ###")
        XCTAssertEqual(MarkdownSection.parse("```\n# Unclosed code\n"), [])
        XCTAssertEqual(MarkdownSection.parse("Plain text without headings."), [])
    }

    func testHoverWidthsFormSymmetricBellCurveAndResetToUniformWidths() {
        XCTAssertEqual(MarkdownSectionEmphasis.width(index: 3, hoveredIndex: 3), 28)
        for distance in 1...4 {
            XCTAssertEqual(MarkdownSectionEmphasis.width(index: 3 - distance, hoveredIndex: 3),
                           MarkdownSectionEmphasis.width(index: 3 + distance, hoveredIndex: 3))
            XCTAssertGreaterThan(MarkdownSectionEmphasis.width(index: 3 + distance - 1, hoveredIndex: 3),
                                 MarkdownSectionEmphasis.width(index: 3 + distance, hoveredIndex: 3))
        }
        for index in 0..<8 { XCTAssertEqual(MarkdownSectionEmphasis.width(index: index, hoveredIndex: nil), 12) }
    }

    func testDenseOutlineKeepsMajorSectionsAndTracksCurrentAncestor() throws {
        let source = "# Document\n" + (1...12).map { "## Chapter \($0)\n### Details\n#### Examples\n" }.joined()
        let sections = MarkdownSection.parse(source)
        let current = sections.first { $0.title == "Examples" }!
        let overview = MarkdownSectionNavigation.overview(sections, currentID: current.id)
        XCTAssertEqual(overview.count, 13)
        XCTAssertTrue(overview.allSatisfy { $0.level <= 2 })
        let path = MarkdownSectionNavigation.path(to: current.id, in: sections)
        XCTAssertEqual(path.map(\.title), ["Document", "Chapter 1", "Details", "Examples"])
        XCTAssertEqual(MarkdownSectionNavigation.activeID(current.id, in: sections, overview: overview), path[1].id)
        let dense = MarkdownSection.parse((1...150).map { "## Chapter \($0)\n### Child\n" }.joined())
        let active = dense[139]
        let bounded = MarkdownSectionNavigation.overview(dense, currentID: active.id)
        XCTAssertLessThanOrEqual(bounded.count, 20)
        XCTAssertEqual(bounded.first?.id, dense.first?.id)
        XCTAssertEqual(bounded.last?.title, "Chapter 150")
        XCTAssertEqual(MarkdownSectionNavigation.activeID(active.id, in: dense, overview: bounded), dense[138].id)
    }

    func testOutlineCollapseAndSearchFindDeepAndDuplicateHeadings() {
        let sections = MarkdownSection.parse("# Document\n## First\n### Details\n#### Deep target\n## Second\n### Details\n")
        XCTAssertEqual(MarkdownSectionNavigation.visible(sections, expanded: [], search: "").map(\.title), ["Document"])
        let initial = MarkdownSectionNavigation.initiallyExpanded(sections, currentID: sections[0].id)
        XCTAssertEqual(MarkdownSectionNavigation.visible(sections, expanded: initial, search: "").map(\.title), ["Document", "First", "Second"])
        let activeBranch = MarkdownSectionNavigation.initiallyExpanded(sections, currentID: sections[3].id)
        XCTAssertEqual(MarkdownSectionNavigation.visible(sections, expanded: activeBranch, search: "").map(\.title), ["Document", "First", "Details", "Deep target", "Second"])
        let expanded = Set([sections[0].id, sections[1].id])
        XCTAssertEqual(MarkdownSectionNavigation.visible(sections, expanded: expanded, search: "").map(\.title), ["Document", "First", "Details", "Second"])
        XCTAssertEqual(MarkdownSectionNavigation.visible(sections, expanded: [], search: "  DEEP  ").map(\.title), ["Deep target"])
        let matches = MarkdownSectionNavigation.visible(sections, expanded: [], search: "Details")
        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(MarkdownSectionNavigation.path(to: matches[0].id, in: sections).dropLast().map(\.title), ["Document", "First"])
        XCTAssertEqual(MarkdownSectionNavigation.path(to: matches[1].id, in: sections).dropLast().map(\.title), ["Document", "Second"])
    }

    @MainActor func testIndicatorTracksScrollAndNavigationWithoutChangingTextOrSelection() throws {
        _ = NSApplication.shared
        let scroll = MarkdownScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        let coordinator = LiveMarkdownEditor.Coordinator()
        let source = "# Start\n\n" + String(repeating: "First section paragraph.\n\n", count: 35) +
            "## Middle\n\n" + String(repeating: "Middle section paragraph.\n\n", count: 35) +
            "### End\n\n" + String(repeating: "End section paragraph.\n\n", count: 35)
        coordinator.update(LiveMarkdownEditor(documentID: "sections", text: source, editing: false, onChange: { _ in }, onLink: { _ in }), scroll: scroll)
        scroll.layoutSubtreeIfNeeded()
        let view = try XCTUnwrap(coordinator.editors["sections"])
        try view.layoutManager?.ensureLayout(for: XCTUnwrap(view.textContainer))
        view.sizeToFit()
        scroll.refreshSectionIndicator()
        XCTAssertEqual(scroll.sectionState.sections.map(\.title), ["Start", "Middle", "End"])
        XCTAssertEqual(scroll.sectionState.currentID, scroll.sectionState.sections.first?.id)
        let selection = view.selectedRange()
        let middle = scroll.sectionState.sections[1]
        scroll.navigate(to: middle)
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 500)
        XCTAssertEqual(scroll.sectionState.currentID, middle.id)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: view.frame.height - 500))
        scroll.refreshSectionIndicator()
        XCTAssertEqual(scroll.sectionState.currentID, scroll.sectionState.sections.last?.id)
        XCTAssertEqual(view.string, source)
        XCTAssertEqual(view.selectedRange(), selection)
        coordinator.update(LiveMarkdownEditor(documentID: "plain", text: "No headings", editing: true, onChange: { _ in }, onLink: { _ in }), scroll: scroll)
        scroll.refreshSectionIndicator()
        XCTAssertTrue(scroll.sectionState.sections.isEmpty)
        XCTAssertNil(scroll.sectionState.currentID)
    }
}
