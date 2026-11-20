import AppKit
import SwiftTerm
import XCTest
@testable import museterm

@MainActor
final class TerminalSSHExitResetTests: XCTestCase {
    private func view() -> FocusableLocalProcessTerminalView {
        let view = FocusableLocalProcessTerminalView(frame: .init(x: 0, y: 0, width: 800, height: 600))
        view.externalIsRunning = { false }
        return view
    }

    private func screen(_ view: FocusableLocalProcessTerminalView) -> String {
        view.visibleRowsText(0..<view.terminalDimensions.rows).joined(separator: "\n")
    }

    private func history(_ view: FocusableLocalProcessTerminalView) -> Data {
        view.getBufferAsData(kind: .normal)
    }

    private func finish(_ view: FocusableLocalProcessTerminalView) {
        var finished = false
        view.finishSSHSessionAfterPendingOutput(ifCurrent: { true }) { finished = true }
        XCTAssertTrue(finished)
    }

    func testAlternateScreenExitRestoresNormalScreenAndAllScrollback() {
        let view = view()
        view.feed(text: (0..<80).map { "__HISTORY_\($0)__\r\n" }.joined() + "__NORMAL_PROMPT__")
        let original = history(view)
        view.feed(text: "\u{1b}[?1049h\u{1b}[H__TUI_TOP__\u{1b}[12;1H__TUI_FOOTER__")
        XCTAssertTrue(view.terminalInputStateSnapshot()?.isAlternateBuffer == true)
        finish(view)
        XCTAssertTrue(view.terminalInputStateSnapshot()?.isAlternateBuffer == false)
        XCTAssertEqual(history(view), original)
        XCTAssertTrue(screen(view).contains("__NORMAL_PROMPT__"))
        XCTAssertFalse(screen(view).contains("__TUI_"))
        view.feed(text: "\r\n__DISCONNECTED__")
        XCTAssertTrue(screen(view).contains("__DISCONNECTED__"))
        XCTAssertTrue(String(decoding: history(view), as: UTF8.self).contains("__HISTORY_0__"))
    }

    func testOrdinaryScreenExitPreservesCellsHistoryAndCursor() {
        let view = view()
        view.feed(text: "__NORMAL_OUTPUT__\r\n__PROMPT__")
        let original = history(view)
        let cursor = view.terminalStateSnapshot().cursor
        finish(view)
        XCTAssertEqual(history(view), original)
        XCTAssertEqual(view.terminalStateSnapshot().cursor, cursor)
        view.feed(text: "\r\n__DISCONNECTED__")
        XCTAssertTrue(screen(view).contains("__NORMAL_OUTPUT__"))
        XCTAssertTrue(screen(view).contains("__PROMPT__"))
    }

    func testLegacyAlternateModesReturnToNormalWithoutErasingIt() {
        for mode in [47, 1047, 1049] {
            let view = view()
            // DECSC predates the final output. Modes 47/1047 do not update it;
            // mode 1049 must instead preserve the position at its own entry.
            view.feed(text: "__ROW_0__\r\n\u{1b}7__ROW_1__\r\n__ROW_2__\r\n__PROMPT__")
            let original = history(view)
            let normalRows = view.visibleRowsText(0..<view.terminalDimensions.rows)
            let normalCursor = view.terminalStateSnapshot().cursor
            view.feed(text: "\u{1b}[?\(mode)h\u{1b}[H__LEGACY_TUI__\u{1b}[12;7H")
            finish(view)
            XCTAssertTrue(view.terminalInputStateSnapshot()?.isAlternateBuffer == false, "mode \(mode)")
            XCTAssertEqual(history(view), original, "mode \(mode)")
            XCTAssertEqual(view.terminalStateSnapshot().cursor, normalCursor, "mode \(mode)")
            XCTAssertEqual(view.visibleRowsText(0..<normalRows.count), normalRows, "mode \(mode)")

            view.feed(text: "\r\n__DISCONNECTED__\r\n__RECONNECTING__")
            var expectedRows = normalRows
            expectedRows[normalCursor.row + 1] = "__DISCONNECTED__"
            expectedRows[normalCursor.row + 2] = "__RECONNECTING__"
            XCTAssertEqual(view.visibleRowsText(0..<normalRows.count), expectedRows, "mode \(mode)")
        }
    }

    func testResetRestoresInputModesAttributesMarginsAndCursorStyle() throws {
        let view = view()
        let originalStyle = view.terminalStateSnapshot().cursorStyle
        let defaultAttribute = view.terminalContentSnapshot(region: .history(maximumScrollbackRows: 0))?.rows.first?.cells.first?.attribute
        view.feed(text: "\u{1b}[>31u\u{1b}[?1049h\u{1b}[>31u")
        view.feed(text: "\u{1b}[?1;66;1000;1004;1006;1007;2004;2026h\u{1b}[?25l\u{1b}[2;5r\u{1b}[?6h\u{1b}[1;31m\u{1b}[6 q")
        finish(view)
        let state = try XCTUnwrap(view.terminalInputStateSnapshot())
        XCTAssertFalse(state.isAlternateBuffer)
        XCTAssertFalse(state.applicationCursor)
        XCTAssertFalse(state.applicationKeypad)
        XCTAssertFalse(state.bracketedPasteMode)
        XCTAssertFalse(state.focusReportingEnabled)
        XCTAssertEqual(state.mouseMode, .off)
        XCTAssertEqual(state.mouseProtocolEncoding, .x10)
        XCTAssertTrue(state.keyboardEnhancementFlags.isEmpty)
        XCTAssertEqual(view.terminalStateSnapshot().cursorStyle, originalStyle)

        // Home must address the whole screen after resetting origin/margin modes.
        view.feed(text: "\u{1b}[H__DEFAULT_STYLE__")
        let content = try XCTUnwrap(view.terminalContentSnapshot(region: .history(maximumScrollbackRows: 0)))
        XCTAssertTrue(content.rows.first?.text.hasPrefix("__DEFAULT_STYLE__") == true)
        XCTAssertNotNil(defaultAttribute)
        XCTAssertEqual(content.rows.first?.cells.first?.attribute, defaultAttribute)
        let lastRow = view.terminalDimensions.rows
        view.feed(text: "\u{1b}[\(lastRow);1H__BOTTOM__\r\n__AFTER_SCROLL__")
        XCTAssertTrue(screen(view).contains("__AFTER_SCROLL__"))
        XCTAssertFalse(screen(view).contains("__DEFAULT_STYLE__"), "Full-height scroll must move the first row into history")
    }

    func testResetClearsInsertionModeInBothBuffers() {
        for alternate in [false, true] {
            let view = view()
            view.feed(text: "ABC\r\u{1b}[4h")
            if alternate { view.feed(text: "\u{1b}[?1049hABC\r\u{1b}[4h") }
            finish(view)
            view.feed(text: "X")
            XCTAssertEqual(view.visibleRowsText(0..<1), ["XBC"], "normal buffer, alternate=\(alternate)")
            view.feed(text: "\u{1b}[?1049h\u{1b}[2J\u{1b}[HABC\rX")
            XCTAssertEqual(view.visibleRowsText(0..<1), ["XBC"], "next alternate buffer")
        }
    }

    func testResetRestoresDefaultAlternateScreenWheelMode() {
        for mode in ["h", "l"] {
            let view = view()
            var writes: [String] = []
            view.externalSend = { bytes, _ in writes.append(String(decoding: bytes, as: UTF8.self)); return true }
            view.feed(text: "\u{1b}[?1007" + mode)
            finish(view)
            XCTAssertTrue(writes.isEmpty)
            // A reconnected TUI that only enters the alternate screen must retain
            // SwiftTerm's default wheel-to-arrow behavior without setting 1007.
            view.feed(text: "\u{1b}[?1049h\u{1b}[?1007$p")
            XCTAssertEqual(writes, ["\u{1b}[?1007;1$y"])
        }
    }

    func testResetCancelsPartialControlSequencesWithoutDispatchingThemOrSendingInput() {
        for partial in ["\u{1b}", "\u{1b}[?10", "\u{1b}[1;", "\u{1b}]0;unfinished title",
                        "\u{1b}]999;unfinished payload", "\u{1b}P$qm", "\u{1b}P+q544e",
                        "\u{1b}Pq#0;2;100;0;0~$", "\u{1b}P1;2", "\u{1b}_Gunterminated"] {
            let view = view()
            var writes: [[UInt8]] = []
            var titles: [String] = []
            view.externalSend = { bytes, _ in writes.append(bytes); return true }
            view.externalBackendSend = { bytes in writes.append(bytes); return true }
            view.onTerminalTitle = { titles.append($0) }
            view.feed(text: "__NORMAL__\u{1b}[?1049h__TUI__" + partial)
            finish(view)
            view.feed(text: "\r\n__DISCONNECTED__")
            XCTAssertTrue(view.terminalInputStateSnapshot()?.isAlternateBuffer == false, partial.debugDescription)
            XCTAssertTrue(screen(view).contains("__NORMAL__"), partial.debugDescription)
            XCTAssertTrue(screen(view).contains("__DISCONNECTED__"), partial.debugDescription)
            XCTAssertTrue(titles.isEmpty, partial.debugDescription)
            XCTAssertTrue(writes.isEmpty, partial.debugDescription)
        }
    }

    func testSessionExitDiscardsUnfinishedDCSWithoutCompletingHandlers() {
        let sequences = [
            (header: "\u{1b}P$q", payload: "m"),
            (header: "\u{1b}P+q", payload: "544e"),
            (header: "\u{1b}Pq", payload: "#0;2;100;0;0~$")
        ]
        for sequence in sequences {
            let delegate = SSHExitTerminalDelegate()
            let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 80, rows: 24))
            terminal.feed(text: "__NORMAL__\r\n" + sequence.header)
            terminal.feed(text: sequence.payload)
            XCTAssertTrue(delegate.writes.isEmpty)
            XCTAssertEqual(delegate.bitmapCount, 0)

            terminal.prepareForSessionExit()
            terminal.softReset()
            terminal.feed(text: "__DISCONNECTED__")
            XCTAssertTrue(delegate.writes.isEmpty, sequence.header.debugDescription)
            XCTAssertEqual(delegate.bitmapCount, 0, sequence.header.debugDescription)
            let text = String(decoding: terminal.getBufferAsData(kind: .normal), as: UTF8.self)
            XCTAssertTrue(text.contains("__NORMAL__"))
            XCTAssertTrue(text.contains("__DISCONNECTED__"))

            // Completed sequences still work after discarding the old handler.
            terminal.feed(text: "\u{1b}P$qm\u{1b}\\")
            XCTAssertEqual(delegate.writes.count, 1)
            terminal.feed(text: "\u{1b}Pq#0;2;100;0;0~$\u{1b}\\")
            XCTAssertEqual(delegate.bitmapCount, 1)
        }
    }

    func testSessionExitResetsAllCharacterSetsAndPrintsPlainText() {
        let shifts = ["\u{f}", "\u{e}", "\u{1b}n", "\u{1b}o"]
        for alternate in [false, true] {
            for activeShift in shifts {
                let view = view()
                view.feed(text: "__NORMAL__\r\n")
                if alternate { view.feed(text: "\u{1b}[?1049h") }
                view.feed(text: "\u{1b}(0\u{1b})0\u{1b}*0\u{1b}+0" + activeShift + "lqqk")
                XCTAssertTrue(screen(view).contains("┌──┐"), "The fixture must activate DEC graphics")
                let original = history(view)
                finish(view)
                XCTAssertEqual(history(view), original)

                var row = view.terminalStateSnapshot().cursor.row + 1
                view.feed(text: "\r\nDisconnected: lqkx")
                XCTAssertEqual(view.visibleRowsText(row..<(row + 1)), ["Disconnected: lqkx"])
                for (index, shift) in shifts.enumerated() {
                    row += 1
                    let text = "G\(index): lqkx"
                    view.feed(text: shift + "\r\n" + text)
                    XCTAssertEqual(view.visibleRowsText(row..<(row + 1)), [text], "G\(index)")
                }
            }
        }
    }

    func testResetRestoresVisibleCursorAndEndsSynchronizedOutput() {
        let view = view()
        var writes: [String] = []
        view.externalSend = { bytes, _ in writes.append(String(decoding: bytes, as: UTF8.self)); return true }
        view.feed(text: "\u{1b}[?25l\u{1b}[?2026h")
        finish(view)
        XCTAssertTrue(writes.isEmpty, "Local cleanup must not write to any backend")
        // Query the emulator after cleanup; the fake backend records the replies.
        view.feed(text: "\u{1b}[?25$p\u{1b}[?2026$p")
        XCTAssertEqual(writes, ["\u{1b}[?25;1$y", "\u{1b}[?2026;2$y"])
    }

    func testBackloggedOutputIsParsedBeforeResetAndNoticeWithoutLosingFrameAcknowledgement() async {
        let view = view()
        view.feed(text: "__MAIN__")
        let acknowledged = expectation(description: "runtime frame acknowledged")
        let reset = expectation(description: "exit reset after all queued output")
        // Larger than one parser tick. The final bytes deliberately leave the TUI
        // and input modes active, so an early reset would be undone by this tail.
        let queued = String(repeating: "\u{1b}[0m", count: 80_000)
            + "\r\n__FINAL_MAIN_OUTPUT__\u{1b}[?1049h\u{1b}[H__FINAL_TUI__\u{1b}[?2004h"
        view.receiveExternal(Data(queued.utf8)) { acknowledged.fulfill() }
        var didFinish = false
        view.finishSSHSessionAfterPendingOutput(ifCurrent: { true }) {
            didFinish = true
            XCTAssertTrue(String(decoding: self.history(view), as: UTF8.self).contains("__FINAL_MAIN_OUTPUT__"))
            view.feed(text: "\r\n__DISCONNECTED__")
            reset.fulfill()
        }
        XCTAssertFalse(didFinish, "Cleanup must wait for queued parser work")
        await fulfillment(of: [reset, acknowledged], timeout: 5)
        XCTAssertTrue(view.terminalInputStateSnapshot()?.isAlternateBuffer == false)
        XCTAssertTrue(view.terminalInputStateSnapshot()?.bracketedPasteMode == false)
        XCTAssertTrue(screen(view).contains("__DISCONNECTED__"))
        XCTAssertFalse(screen(view).contains("__FINAL_TUI__"))
    }

    func testResetIsIdempotentAndDoesNotTriggerTruncatedReplayViewportErasure() {
        let view = view()
        view.feed(text: "__NORMAL__")
        view.beginTruncatedRuntimeReplay()
        finish(view)
        let original = history(view)
        let cursor = view.terminalStateSnapshot().cursor
        finish(view)
        XCTAssertEqual(history(view), original)
        XCTAssertEqual(view.terminalStateSnapshot().cursor, cursor)
        XCTAssertTrue(screen(view).contains("__NORMAL__"))
        view.feed(text: "\u{1b}[?1049l__PROMPT__")
        XCTAssertTrue(screen(view).contains("__NORMAL__"))
    }

    func testQueuedCleanupCannotResetSupersedingConnectionOrLiveBackend() async {
        for liveBackend in [false, true] {
            let view = view()
            let parsed = expectation(description: "pending output parsed")
            view.receiveExternal(Data("\u{1b}[?1049h__NEW_TUI__\u{1b}[?2004h".utf8)) { parsed.fulfill() }
            var currentAttempt = true
            view.finishSSHSessionAfterPendingOutput(ifCurrent: { currentAttempt }) {
                XCTFail("A superseded exit must not complete")
            }
            if liveBackend { view.externalIsRunning = { true } }
            else { currentAttempt = false }
            await fulfillment(of: [parsed], timeout: 5)
            XCTAssertTrue(view.terminalInputStateSnapshot()?.isAlternateBuffer == true)
            XCTAssertTrue(view.terminalInputStateSnapshot()?.bracketedPasteMode == true)
            XCTAssertTrue(screen(view).contains("__NEW_TUI__"))
        }
    }

    func testControllerOnlyResetsConfirmedSSHExitOnceAndNeverALiveBackend() throws {
        let session = TerminalSession(sequence: 1, launchConfiguration: .ssh(.init(
            name: "exit-test", host: "invalid.test", automaticReconnectEnabled: false)))
        let view = try XCTUnwrap(session.controller.container.subviews.compactMap { $0 as? FocusableLocalProcessTerminalView }.first)
        view.externalIsRunning = { true }
        view.feed(text: "__NORMAL__\u{1b}[?1049h__LIVE_TUI__")
        session.controller.processTerminated(source: view, exitCode: 255)
        XCTAssertTrue(view.terminalInputStateSnapshot()?.isAlternateBuffer == true)
        view.externalIsRunning = { false }
        session.controller.processTerminated(source: view, exitCode: 255)
        XCTAssertTrue(view.terminalInputStateSnapshot()?.isAlternateBuffer == false)
        XCTAssertTrue(screen(view).contains("__NORMAL__"))
        // A duplicate callback must not reset newly configured interaction state.
        view.feed(text: "\u{1b}[?2004h")
        session.controller.processTerminated(source: view, exitCode: 255)
        XCTAssertTrue(view.terminalInputStateSnapshot()?.bracketedPasteMode == true)
    }

    func testLocalShellExitDoesNotRunSSHCleanup() throws {
        let session = TerminalSession(sequence: 1)
        let view = try XCTUnwrap(session.controller.container.subviews.compactMap { $0 as? FocusableLocalProcessTerminalView }.first)
        view.externalIsRunning = { false }
        view.feed(text: "\u{1b}[?1049h__LOCAL_TUI__")
        session.controller.processTerminated(source: view, exitCode: 0)
        XCTAssertTrue(view.terminalInputStateSnapshot()?.isAlternateBuffer == true)
    }
}

private final class SSHExitTerminalDelegate: TerminalDelegate {
    private(set) var writes: [[UInt8]] = []
    private(set) var bitmapCount = 0

    func send(source: Terminal, data: ArraySlice<UInt8>) {
        writes.append(Array(data))
    }

    func createImageFromBitmap(source: Terminal, bytes: inout [UInt8], width: Int, height: Int) {
        bitmapCount += 1
    }
}
