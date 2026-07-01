import XCTest
@testable import museterm

final class TerminalShellArgumentEscaperTests: XCTestCase {
    func testQuotesPlainSelectionForPathUse() {
        XCTAssertEqual(
            TerminalShellArgumentEscaper.escapedPathArgument(fromTerminalSelection: "hello world"),
            "'hello world'"
        )
        XCTAssertEqual(
            TerminalShellArgumentEscaper.escapedPathArgument(fromTerminalSelection: "weird'name"),
            "'weird'\\''name'"
        )
        XCTAssertEqual(
            TerminalShellArgumentEscaper.escapedPathArgument(fromTerminalSelection: "-starts-with-dash"),
            "./'-starts-with-dash'"
        )
    }

    func testPreservesExistingShellEscapedSelection() {
        XCTAssertEqual(
            TerminalShellArgumentEscaper.escapedPathArgument(fromTerminalSelection: "''$'\\344\\270\\213'"),
            "''$'\\344\\270\\213'"
        )
        XCTAssertEqual(
            TerminalShellArgumentEscaper.escapedPathArgument(fromTerminalSelection: "file\\ name"),
            "file\\ name"
        )
        XCTAssertEqual(
            TerminalShellArgumentEscaper.typedArgument(fromTerminalSelection: "file name"),
            " 'file name'"
        )
    }

    func testRejectsEmptyOrMultilineSelection() {
        XCTAssertNil(TerminalShellArgumentEscaper.escapedPathArgument(fromTerminalSelection: "  "))
        XCTAssertNil(TerminalShellArgumentEscaper.escapedPathArgument(fromTerminalSelection: "one\ntwo"))
    }
}
