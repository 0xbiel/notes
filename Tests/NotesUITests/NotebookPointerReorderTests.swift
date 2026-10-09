import XCTest
import AppKit
@testable import Notes

final class NotebookPointerReorderTests: XCTestCase {
    let headers: [NotebookPointerReorder.Header] = [
        .init(id: "a", rect: NSRect(x: 0, y: 0, width: 200, height: 40)),
        .init(id: "b", rect: NSRect(x: 0, y: 160, width: 200, height: 60)),
        .init(id: "c", rect: NSRect(x: 0, y: 220, width: 200, height: 40))
    ]
    func testClickAndDragAreSeparateAndReleaseCommitsOnce() {
        var state = NotebookPointerReorder()
        state.begin(id: "c", at: NSPoint(x: 70, y: 240))
        state.move(to: NSPoint(x: 72, y: 241), headers: headers, inside: true)
        XCTAssertEqual(state.finish(), .click("c"))
        for _ in 0..<100 {
            state.begin(id: "c", at: NSPoint(x: 70, y: 240))
            state.move(to: NSPoint(x: 70, y: 30), headers: headers, inside: true)
            XCTAssertEqual(state.insertionY, 160) // Below a's expanded descendants.
            XCTAssertEqual(state.finish(), .move("c", "a", true))
            XCTAssertNil(state.finish())
        }
    }
    func testUpwardDownwardAndLastExpandedBoundary() {
        var state = NotebookPointerReorder()
        state.begin(id: "c", at: NSPoint(x: 70, y: 240))
        state.move(to: NSPoint(x: 70, y: 5), headers: headers, inside: true)
        XCTAssertEqual(state.insertionY, 0)
        XCTAssertEqual(state.finish(), .move("c", "a", false))
        var expanded = headers
        expanded[2] = .init(id: "c", rect: headers[2].rect, subtreeEnd: 400)
        state.begin(id: "a", at: NSPoint(x: 70, y: 20))
        state.move(to: NSPoint(x: 70, y: 350), headers: expanded, inside: true)
        XCTAssertEqual(state.insertionY, 400)
        XCTAssertEqual(state.finish(), .move("a", "c", true))
    }
    func testOutsideEscapeAndReturningToSourceCancel() {
        var state = NotebookPointerReorder()
        state.begin(id: "a", at: NSPoint(x: 70, y: 20))
        state.move(to: NSPoint(x: 270, y: 250), headers: headers, inside: false)
        XCTAssertNil(state.finish())
        state.begin(id: "a", at: NSPoint(x: 70, y: 20))
        state.move(to: NSPoint(x: 70, y: 250), headers: headers, inside: true)
        state.cancel()
        XCTAssertNil(state.finish())
        state.begin(id: "a", at: NSPoint(x: 70, y: 20))
        state.move(to: NSPoint(x: 70, y: 250), headers: headers, inside: true)
        state.move(to: NSPoint(x: 70, y: 20), headers: headers, inside: true)
        XCTAssertNil(state.finish())
    }
}
