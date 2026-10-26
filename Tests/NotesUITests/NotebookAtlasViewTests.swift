import XCTest
import SwiftUI
import LectureCore
@testable import Notes

final class NotebookAtlasViewTests: XCTestCase {
    @MainActor private func environment() throws -> (Workbench, URL) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".test-workspaces/NotebookAtlasView-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("copied-course"), withIntermediateDirectories: true)
        try Data("# Inicio\n\nNota inventada.\n\n## Segunda parte\n\nMás texto inventado.\n".utf8).write(to: root.appendingPathComponent("copied-course/Inicio.md"))
        try JSONSerialization.data(withJSONObject: ["originalRoot": root.appendingPathComponent("original").path]).write(to: root.appendingPathComponent("original-hashes.json"))
        let model = Workbench(workspaceRoot: root)
        XCTAssertNil(model.errorText)
        return (model, root)
    }

    @MainActor func testAtlasReplacesTheNotebookHomeAndAPlaceOpensItsHeading() throws {
        let (model, root) = try environment()
        defer { model.media?.shutdown(); model.ai?.stop(); model.maps?.shutdown(); try? FileManager.default.removeItem(at: root) }
        XCTAssertNotNil(model.maps)
        XCTAssertFalse(model.mapVisible)
        model.toggleMap()
        XCTAssertTrue(model.mapVisible)
        XCTAssertNil(model.selectedNote)
        model.openMapItem(.init(id: "Inicio.md#Segunda parte", kind: .section, path: "Inicio.md", heading: "Segunda parte", title: "Segunda parte", file: "Inicio", digest: ""))
        XCTAssertEqual(model.selectedNote, "Inicio.md")
        XCTAssertEqual(model.previewHeading, "Segunda parte")
        // The atlas waits behind the note and returns with the notebook.
        XCTAssertFalse(model.mapVisible)
        model.openNotebook(model.currentNotebook.id)
        XCTAssertTrue(model.mapVisible)
        model.toggleMap()
        XCTAssertFalse(model.mapVisible)
    }

    @MainActor func testWithoutTheModelTheAtlasOffersToDownloadIt() throws {
        let (model, root) = try environment()
        defer { model.media?.shutdown(); model.ai?.stop(); model.maps?.shutdown(); try? FileManager.default.removeItem(at: root) }
        let maps = try XCTUnwrap(model.maps)
        XCTAssertFalse(maps.installed)
        model.toggleMap()
        // Nothing is read, downloaded or started until the reader asks for the model.
        model.refreshMap()
        XCTAssertFalse(maps.reading)
        XCTAssertNil(maps.download)
        let host = NSHostingView(rootView: NotebookAtlasView(model: model, maps: maps).frame(width: 900, height: 600).background(Color(nsColor: .textBackgroundColor)).environment(\.colorScheme, .light))
        host.appearance = NSAppearance(named: .aqua)
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 600); host.layoutSubtreeIfNeeded()
        if let path = ProcessInfo.processInfo.environment["NOTES_MAP_SETUP_SCREENSHOT"] {
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
        }
    }

    /// Set PALLADIUM_MAP_WORKSPACE to a workspace with the model installed in its `embedding` folder and
    /// NOTES_MAP_SCREENSHOT to a PNG path: the library is read with the real model and its atlas captured.
    @MainActor func testRealAtlasScreenshot() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let workspace = environment["PALLADIUM_MAP_WORKSPACE"], let path = environment["NOTES_MAP_SCREENSHOT"] else { throw XCTSkip("Set PALLADIUM_MAP_WORKSPACE and NOTES_MAP_SCREENSHOT.") }
        let model = Workbench(workspaceRoot: URL(fileURLWithPath: workspace))
        defer { model.media?.shutdown(); model.ai?.stop(); model.maps?.shutdown() }
        XCTAssertNil(model.errorText)
        let maps = try XCTUnwrap(model.maps)
        XCTAssertTrue(maps.installed)
        model.toggleMap()
        model.refreshMap()
        for _ in 0..<600 where maps.reading { try await Task.sleep(for: .milliseconds(200)) }
        XCTAssertNil(maps.error)
        let atlas = try XCTUnwrap(maps.atlas)
        XCTAssertGreaterThan(atlas.points.count, 0)
        for (suffix, focus, scheme) in [("", nil as Int?, NSAppearance.Name.aqua), (".dark", nil, .darkAqua), (".focus", 0, .aqua)] {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: scheme)
            let host = NSHostingView(rootView: NotebookAtlasView(model: model, maps: maps, focus: focus))
            window.contentView = host
            window.setFrameOrigin(NSPoint(x: -6000, y: -6000)); window.orderFrontRegardless()
            defer { window.orderOut(nil) }
            host.layoutSubtreeIfNeeded()
            // The points settle and the camera finishes its flight before the picture is taken.
            try await Task.sleep(for: .seconds(4))
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds)); host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: suffix + ".png")))
        }
    }
}

/// Drives the atlas through the window the way a pointer would, so the controls drawn over the graph are part of
/// what is tested.
final class NotebookAtlasInteractionTests: XCTestCase {
    @MainActor private func prepare() throws -> (Workbench, NotebookMapController, NSWindow, NotebookAtlasGraphView, URL) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".test-workspaces/NotebookAtlasInteraction-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("copied-course"), withIntermediateDirectories: true)
        try Data("# Inicio\n\nNota inventada.\n\n## Segunda parte\n\nMás texto inventado.\n".utf8).write(to: root.appendingPathComponent("copied-course/Inicio.md"))
        try JSONSerialization.data(withJSONObject: ["originalRoot": root.appendingPathComponent("original").path]).write(to: root.appendingPathComponent("original-hashes.json"))
        let model = Workbench(workspaceRoot: root)
        let workspace = try XCTUnwrap(model.workspace), maps = try XCTUnwrap(model.maps)
        // Three invented notebooks of twelve places each, every place opening the same heading.
        var generator = SplitMixForTests(seed: 7)
        let sources = (0..<3).map { book -> NotebookAtlasBuilder.Source in
            var index = NotebookMapIndex()
            index.entries = (0..<12).map { place in
                var vector = (0..<NotebookEmbeddingRuntime.dimensions).map { _ in Float.random(in: -0.1...0.1, using: &generator) }
                vector[book] += 1; vector[3 + place % 3] += 0.6
                return .init(item: .init(id: "b\(book)p\(place)", kind: .section, path: "Inicio.md", heading: "Segunda parte", title: "Lugar \(place)", file: "Libro \(book)", digest: ""), vector: NotebookMapIndex.pack(vector))
            }
            return .init(id: "book\(book)", name: "Libro \(book)", index: index)
        }
        try NotebookAtlasBuilder.build(sources).save(workspace: workspace)
        maps.load()
        XCTAssertEqual(maps.atlas?.regions.count, 3)
        model.toggleMap()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: NotebookAtlasView(model: model, maps: maps))
        window.contentView?.layoutSubtreeIfNeeded()
        // Kept off every screen: the window server still delivers what is sent to it.
        window.setFrameOrigin(NSPoint(x: -6000, y: -6000)); window.orderFrontRegardless()
        func find(_ view: NSView) -> NotebookAtlasGraphView? { view as? NotebookAtlasGraphView ?? view.subviews.lazy.compactMap(find).first }
        let graph = try XCTUnwrap(find(try XCTUnwrap(window.contentView)))
        return (model, maps, window, graph, root)
    }
    @MainActor private func send(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) {
        window.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!)
    }
    /// Where a point of the graph is, in window coordinates.
    @MainActor private func spot(_ index: Int, _ graph: NotebookAtlasGraphView) -> NSPoint { graph.convert(graph.screen(graph.nodes[index].position), to: nil) }
    @MainActor private func drag(from start: NSPoint, by offset: CGVector, in window: NSWindow) async throws {
        send(.leftMouseDown, at: start, in: window)
        for step in 1...10 {
            send(.leftMouseDragged, at: NSPoint(x: start.x + offset.dx * CGFloat(step) / 10, y: start.y + offset.dy * CGFloat(step) / 10), in: window)
            try await settle(0.02)
        }
        send(.leftMouseUp, at: NSPoint(x: start.x + offset.dx, y: start.y + offset.dy), in: window)
    }
    @MainActor private func settle(_ seconds: Double = 0.3, graph: NotebookAtlasGraphView? = nil) async throws {
        // Offscreen windows do not receive CADisplayLink callbacks. Advance the real
        // simulation and camera code while allowing SwiftUI updates to run.
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(16))
            graph?.advanceFrame()
        }
    }
    /// A point that is shown and clear of the panels laid over the graph.
    @MainActor private func clearPoint(_ graph: NotebookAtlasGraphView, _ window: NSWindow) throws -> Int {
        let height = try XCTUnwrap(window.contentView).bounds.height
        return try XCTUnwrap(graph.nodes.indices.first { let at = spot($0, graph); return at.x > 320 && at.x < 900 && at.y > 60 && at.y < height - 140 })
    }

    @MainActor func testDraggingTheBackgroundPansAndScrollingZooms() async throws {
        let (model, _, window, graph, root) = try prepare()
        defer { window.orderOut(nil); model.media?.shutdown(); model.ai?.stop(); model.maps?.shutdown(); try? FileManager.default.removeItem(at: root) }
        try await settle(1)
        // An empty spot in the middle reaches the graph, not the controls laid over it.
        let empty = try XCTUnwrap(stride(from: 400, to: 900, by: 20).lazy.flatMap { x in stride(from: 100, to: 600, by: 20).map { NSPoint(x: x, y: $0) } }
            .first { graph.node(at: graph.convert($0, from: nil)) == nil })
        let hit = try XCTUnwrap(window.contentView?.hitTest(empty))
        XCTAssertTrue(hit === graph || hit.isDescendant(of: graph), "\(hit) takes the pointer over the graph")
        let centre = graph.centre
        try await drag(from: empty, by: CGVector(dx: 120, dy: -60), in: window)
        XCTAssertEqual(graph.centre.x, centre.x - 120 / graph.scale, accuracy: 1, "dragging the background did not pan")
        XCTAssertNil(model.selectedNote, "a drag opened a place")

        let scale = graph.scale
        let scroll = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 60, wheel2: 0, wheel3: 0))
        scroll.location = CGPoint(x: window.frame.minX + empty.x, y: NSScreen.screens[0].frame.height - (window.frame.minY + empty.y))
        window.sendEvent(try XCTUnwrap(NSEvent(cgEvent: scroll)))
        XCTAssertGreaterThan(graph.scale, scale * 1.1, "scrolling did not zoom in")
    }

    @MainActor func testAPointCanBeDraggedAndItsNeighboursFollow() async throws {
        let (model, _, window, graph, root) = try prepare()
        defer { window.orderOut(nil); model.media?.shutdown(); model.ai?.stop(); model.maps?.shutdown(); try? FileManager.default.removeItem(at: root) }
        try await settle(2)
        let index = try clearPoint(graph, window), start = spot(index, graph)
        let neighbour = try XCTUnwrap(graph.edges.first { $0.0 == index || $0.1 == index }.map { $0.0 == index ? $0.1 : $0.0 })
        let neighbourBefore = graph.nodes[neighbour].position
        try await drag(from: start, by: CGVector(dx: 150, dy: 90), in: window)
        let moved = spot(index, graph)
        XCTAssertEqual(moved.x, start.x + 150, accuracy: 6, "the point did not follow the pointer")
        XCTAssertEqual(moved.y, start.y + 90, accuracy: 6)
        try await settle(0.5, graph: graph)
        let after = graph.nodes[neighbour].position
        XCTAssertGreaterThan(hypot(after.x - neighbourBefore.x, after.y - neighbourBefore.y), 1, "its neighbour stayed put")
        XCTAssertNil(model.selectedNote, "dragging a point opened it")
    }

    @MainActor func testHoverNamesAPointAndAClickOpensIt() async throws {
        let (model, _, window, graph, root) = try prepare()
        defer { window.orderOut(nil); model.media?.shutdown(); model.ai?.stop(); model.maps?.shutdown(); try? FileManager.default.removeItem(at: root) }
        try await settle(2)
        let target = spot(try clearPoint(graph, window), graph)
        var hovered: Int?
        let report = graph.hover
        graph.hover = { index, point in hovered = index; report(index, point) }
        send(.mouseMoved, at: target, in: window)
        if hovered == nil { graph.mouseMoved(with: NSEvent.mouseEvent(with: .mouseMoved, location: target, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0)!) }
        XCTAssertNotNil(hovered, "nothing under the pointer")
        send(.leftMouseDown, at: target, in: window)
        send(.leftMouseUp, at: target, in: window)
        try await settle(0.3)
        XCTAssertEqual(model.selectedNote, "Inicio.md", "a click on a point did not open it")
        XCTAssertEqual(model.previewHeading, "Segunda parte")
        XCTAssertFalse(model.mapVisible)
    }

    @MainActor func testPickingARegionFliesToItAndItsSquareHidesIt() async throws {
        let (model, _, window, graph, root) = try prepare()
        defer { window.orderOut(nil); model.media?.shutdown(); model.ai?.stop(); model.maps?.shutdown(); try? FileManager.default.removeItem(at: root) }
        try await settle(1)
        let height = try XCTUnwrap(window.contentView).bounds.height
        // The first row of the region panel: its name, then its colour square to the left.
        let row = NSPoint(x: 150, y: height - 112), square = NSPoint(x: 37, y: height - 108)
        send(.leftMouseDown, at: row, in: window); send(.leftMouseUp, at: row, in: window)
        try await settle(1, graph: graph)
        let members = graph.nodes.filter { $0.region == 0 }
        let middle = CGPoint(x: members.map(\.position.x).reduce(0, +) / CGFloat(members.count), y: members.map(\.position.y).reduce(0, +) / CGFloat(members.count))
        XCTAssertLessThan(hypot(graph.centre.x - middle.x, graph.centre.y - middle.y), 60, "picking the region did not fly to it")
        send(.leftMouseDown, at: square, in: window); send(.leftMouseUp, at: square, in: window)
        try await settle(0.4)
        XCTAssertEqual(graph.hiddenRegions, [0], "the square did not hide the region")
        // A hidden region's points can no longer be hovered or opened.
        for index in graph.nodes.indices where graph.nodes[index].region == 0 {
            XCTAssertNotEqual(graph.node(at: graph.screen(graph.nodes[index].position)), index)
        }
    }
}

/// The same numbers for the same seed, so the invented library is the same on every run.
struct SplitMixForTests: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }
}
