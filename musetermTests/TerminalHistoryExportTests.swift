import SwiftTerm
import XCTest

@MainActor
final class TerminalHistoryExportTests: XCTestCase {
    func testExportsPhysicalRowsWithUnicodeAndPreservesOtherEncodings() {
        let delegate = HistoryExportDelegate()
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 8, rows: 5))
        terminal.feed(text: "\u{1B}[32mA中e\u{301} \u{1B}[0m\r\n\r\n123456789\r\nX\u{1B}[2CY\u{1B}[44m\u{1B}[K")
        let expected = Data("A中e\u{301} \n\n12345678\n9\nX  Y\n".utf8)

        XCTAssertEqual(terminal.getBufferAsData(), expected)
        XCTAssertEqual(terminal.getBufferAsData(kind: .normal), expected)
        // ASCII skips the unrepresentable row, without adding a newline for it.
        XCTAssertEqual(terminal.getBufferAsData(encoding: .ascii), Data("\n12345678\n9\nX  Y\n".utf8))
        XCTAssertEqual(terminal.getBufferAsData(), expected)
    }

    func testRefreshesRewrittenAndRecycledLines() {
        let delegate = HistoryExportDelegate()
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 8, rows: 3, scrollback: 2))
        terminal.feed(text: "old\r\nsecond")
        XCTAssertEqual(terminal.getBufferAsData(), Data("old\nsecond\n\n".utf8))

        terminal.feed(text: "\r\u{1B}[K新")
        XCTAssertEqual(terminal.getBufferAsData(), Data("old\n新\n\n".utf8))

        for index in 0..<10 {
            terminal.feed(text: "\r\nrow\(index)")
            XCTAssertTrue(String(decoding: terminal.getBufferAsData(), as: UTF8.self).hasSuffix("row\(index)\n"))
        }
        XCTAssertGreaterThan(terminal.buffer.totalLinesTrimmed, 0)
        XCTAssertEqual(terminal.getBufferAsData(), Data("row5\nrow6\nrow7\nrow8\nrow9\n".utf8))
    }

    func testKeepsNormalAndAlternateHistorySeparateAcrossResizeAndClear() {
        let delegate = HistoryExportDelegate()
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 8, rows: 3))
        terminal.feed(text: "normal")
        let normal = Data("normal\n\n\n".utf8)
        XCTAssertEqual(terminal.getBufferAsData(), normal)

        terminal.feed(text: "\u{1B}[?1049h\u{1B}[Halt😀")
        let alternate = Data("alt😀\n\n\n".utf8)
        XCTAssertEqual(terminal.getBufferAsData(), alternate)
        XCTAssertEqual(terminal.getBufferAsData(kind: .alt), alternate)
        XCTAssertEqual(terminal.getBufferAsData(kind: .normal), normal)

        terminal.feed(text: "\u{1B}[2J\u{1B}[?1049l")
        XCTAssertEqual(terminal.getBufferAsData(), normal)
        terminal.resize(cols: 4, rows: 4)
        // The row containing the cursor is clipped instead of reflowed.
        XCTAssertEqual(terminal.getBufferAsData(), Data("norm\n\n\n\n".utf8))
        terminal.feed(text: "\u{1B}[2J")
        XCTAssertEqual(terminal.getBufferAsData(), Data("\n\n\n\n".utf8))
    }
}

private final class HistoryExportDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}
