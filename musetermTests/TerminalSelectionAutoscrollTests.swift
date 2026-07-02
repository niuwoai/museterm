import XCTest
@testable import museterm

@MainActor
final class TerminalSelectionAutoscrollTests: XCTestCase {
    func testReturnsNilAwayFromEdges() {
        XCTAssertNil(TerminalSelectionAutoscroll.action(pointerY: 120, viewHeight: 240))
    }

    func testScrollsUpNearTopEdge() throws {
        let action = try XCTUnwrap(TerminalSelectionAutoscroll.action(pointerY: 236, viewHeight: 240))

        XCTAssertEqual(action.direction, .up)
        XCTAssertEqual(action.lines, 2)
    }

    func testScrollsDownNearBottomEdge() throws {
        let action = try XCTUnwrap(TerminalSelectionAutoscroll.action(pointerY: 4, viewHeight: 240))

        XCTAssertEqual(action.direction, .down)
        XCTAssertEqual(action.lines, 2)
    }

    func testSpeedsUpOutsideViewButCapsVelocity() throws {
        let topAction = try XCTUnwrap(TerminalSelectionAutoscroll.action(pointerY: 420, viewHeight: 240))
        let bottomAction = try XCTUnwrap(TerminalSelectionAutoscroll.action(pointerY: -180, viewHeight: 240))

        XCTAssertEqual(topAction.direction, .up)
        XCTAssertEqual(topAction.lines, TerminalSelectionAutoscroll.maximumLinesPerTick)
        XCTAssertEqual(bottomAction.direction, .down)
        XCTAssertEqual(bottomAction.lines, TerminalSelectionAutoscroll.maximumLinesPerTick)
    }

    func testInvalidHeightDoesNotScroll() {
        XCTAssertNil(TerminalSelectionAutoscroll.action(pointerY: 0, viewHeight: 0))
    }
}
