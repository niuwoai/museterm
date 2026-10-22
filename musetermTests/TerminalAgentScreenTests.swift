import SwiftTerm
import XCTest
@testable import museterm

@MainActor
final class TerminalAgentScreenTests: XCTestCase {
    func testLiveTailIgnoresUserScrollPosition() {
        let terminal = Terminal(delegate: AgentScreenDelegate(), options: TerminalOptions(cols: 80, rows: 24))
        terminal.feed(text: "Do you want to proceed?\r\n❯ 1. Yes\r\n2. No\r\n")
        for index in 0..<80 { terminal.feed(text: "ordinary log \(index)\r\n") }
        terminal.buffer.yDisp = 0
        let live = TerminalAgentScreenReader.liveTail(terminal)
        XCTAssertTrue(live.contains("ordinary log 79"))
        XCTAssertFalse(live.contains("Do you want to proceed?"))
        XCTAssertEqual(TerminalAgentScreenRules.detect(kind: .claude, screen: live).activity, .unknown)
        XCTAssertEqual(terminal.buffer.yDisp, 0, "classification must not scroll the user's terminal")
    }

    func testLiveTailFindsApprovalInAlternateScreen() {
        let terminal = Terminal(delegate: AgentScreenDelegate(), options: TerminalOptions(cols: 100, rows: 24))
        terminal.feed(text: "\u{1B}[?1049h\u{1B}[20;1HDo you want to proceed?\r\n❯ 1. Yes\r\n2. No\r\n")
        let live = TerminalAgentScreenReader.liveTail(terminal)
        XCTAssertEqual(TerminalAgentScreenRules.detect(kind: .claude, screen: live).blockReason, .approval)
    }

    func testLiveTailHandlesTrimmedHistoryAndBoundsPayload() {
        let terminal = Terminal(delegate: AgentScreenDelegate(), options: TerminalOptions(cols: 120, rows: 24))
        terminal.changeScrollback(30)
        for index in 0..<500 { terminal.feed(text: "bounded log \(index)\r\n") }
        XCTAssertGreaterThan(terminal.buffer.totalLinesTrimmed, 0)
        let live = TerminalAgentScreenReader.liveTail(terminal)
        XCTAssertTrue(live.contains("bounded log 499"))
        XCTAssertLessThanOrEqual(live.count, TerminalAgentScreenRules.maximumCharacters)
        XCTAssertLessThanOrEqual(live.split(separator: "\n").count, TerminalAgentScreenRules.maximumLines)
    }

    func testLiveTailWorksForEmptySmallTerminal() {
        let terminal = Terminal(delegate: AgentScreenDelegate(), options: TerminalOptions(cols: 10, rows: 2))
        XCTAssertTrue(TerminalAgentScreenReader.liveTail(terminal).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
}

private final class AgentScreenDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}
