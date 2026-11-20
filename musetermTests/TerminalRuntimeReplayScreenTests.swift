import AppKit
import SwiftTerm
import XCTest
@testable import museterm

@MainActor
final class TerminalRuntimeReplayScreenTests: XCTestCase {
    private func view() -> FocusableLocalProcessTerminalView {
        FocusableLocalProcessTerminalView(frame: .init(x: 0, y: 0, width: 800, height: 600))
    }

    private func receive(_ text: String, in view: FocusableLocalProcessTerminalView, historical: Bool = false) async {
        let data = Data(text.utf8)
        await withCheckedContinuation { continuation in
            view.receiveExternal(data, historicalBytes: historical ? data.count : 0) { continuation.resume() }
        }
    }

    private func screen(_ view: FocusableLocalProcessTerminalView) -> String {
        let rows = view.terminalDimensions.rows
        guard rows > 0 else { return "" }
        return view.visibleRowsText(0..<rows).joined(separator: "\n")
    }

    func testMissingAlternateEntryClearsResidueBeforeSameFrameShellPrompt() async {
        let view = view()
        view.beginTruncatedRuntimeReplay()
        await receive("\u{1b}[H__TUI_TOP__\u{1b}[12;1H__TUI_FOOTER__", in: view, historical: true)
        XCTAssertTrue(screen(view).contains("__TUI_FOOTER__"))
        await receive("\u{1b}[?1049l__SHELL_PROMPT__", in: view)
        XCTAssertTrue(screen(view).contains("__SHELL_PROMPT__"))
        XCTAssertFalse(screen(view).contains("__TUI_"))
    }

    func testSplitExitSequenceUsesTheEmulatorsActualSwitchCallback() async {
        let exit = Array("\u{1b}[?1049l".utf8)
        for split in 1..<exit.count {
            let view = view()
            view.beginTruncatedRuntimeReplay()
            await receive("\u{1b}[10;1H__STALE_TUI__", in: view)
            await receive(String(decoding: exit.prefix(split), as: UTF8.self), in: view)
            await receive(String(decoding: exit.dropFirst(split), as: UTF8.self) + "__NEW_SHELL__", in: view)
            XCTAssertTrue(screen(view).contains("__NEW_SHELL__"), "split \(split)")
            XCTAssertFalse(screen(view).contains("__STALE_TUI__"), "split \(split)")
        }
    }

    func testCompleteAlternateCyclePreservesOriginalNormalScreen() async {
        let view = view()
        view.feed(text: "__ORIGINAL_SHELL__")
        view.beginTruncatedRuntimeReplay()
        await receive("\u{1b}[?1049h\u{1b}[H__TUI__\u{1b}[?1049l__PROMPT__", in: view)
        XCTAssertTrue(screen(view).contains("__ORIGINAL_SHELL__"))
        XCTAssertTrue(screen(view).contains("__PROMPT__"))
        XCTAssertFalse(screen(view).contains("__TUI__"))
    }

    func testGapInKnownAlternateScreenPreservesItsSavedNormalScreen() async {
        let view = view()
        view.feed(text: "__SAVED_NORMAL__\u{1b}[?1049h")
        view.beginTruncatedRuntimeReplay()
        await receive("\u{1b}[H__TUI__\u{1b}[?1049l__RESTORED__", in: view)
        XCTAssertTrue(screen(view).contains("__SAVED_NORMAL__"))
        XCTAssertTrue(screen(view).contains("__RESTORED__"))
        XCTAssertFalse(screen(view).contains("__TUI__"))
    }

    func testOrdinaryShellReplayDoesNotClearWithoutAScreenSwitch() async {
        let view = view()
        view.beginTruncatedRuntimeReplay()
        await receive("__SHELL_OUTPUT__\r\nall local files 9l 47l\r\n__PROMPT__", in: view)
        XCTAssertTrue(screen(view).contains("__SHELL_OUTPUT__"))
        XCTAssertTrue(screen(view).contains("__PROMPT__"))
    }

    func testNormalScreenResetWithoutAGapDoesNotEraseShellContent() async {
        let view = view()
        await receive("\u{1b}[10;1H__SHELL_OUTPUT__\u{1b}[?1049l__PROMPT__", in: view)
        XCTAssertTrue(screen(view).contains("__SHELL_OUTPUT__"))
        XCTAssertTrue(screen(view).contains("__PROMPT__"))
    }

    func testTitlePayloadIsNotTreatedAsAScreenExit() async {
        let view = view()
        view.beginTruncatedRuntimeReplay()
        await receive("__SHELL_OUTPUT__\u{1b}]0;title ?1049l\u{7}__PROMPT__", in: view)
        XCTAssertTrue(screen(view).contains("__SHELL_OUTPUT__"))
    }

    func testOrphanExitPreservesScrollbackAndDoesNotInjectInput() async {
        let view = view()
        var writes = 0
        view.externalSend = { _, _ in writes += 1; return true }
        view.feed(text: (0..<80).map { "__HISTORY_\($0)__\r\n" }.joined())
        view.beginTruncatedRuntimeReplay()
        await receive("\u{1b}[H__TUI__\u{1b}[12;1H__STALE__\u{1b}[?1049l__PROMPT__", in: view)
        let history = String(decoding: view.getBufferAsData(kind: .normal), as: UTF8.self)
        XCTAssertTrue(history.contains("__HISTORY_0__"))
        XCTAssertTrue(screen(view).contains("__PROMPT__"))
        XCTAssertFalse(screen(view).contains("__STALE__"))
        XCTAssertEqual(writes, 0)
    }

    func testRecoveryOnlyClearsTheFirstUnmatchedScreenReset() async {
        let view = view()
        view.beginTruncatedRuntimeReplay()
        await receive("__TUI__\u{1b}[?1049l\u{1b}[10;1H__SHELL__\u{1b}[?1049l__PROMPT__", in: view)
        XCTAssertTrue(screen(view).contains("__SHELL__"))
        XCTAssertTrue(screen(view).contains("__PROMPT__"))
    }

    func testLegacyAlternateExitModesRecoverTheViewport() async {
        for mode in [47, 1047] {
            let view = view()
            view.beginTruncatedRuntimeReplay()
            await receive("\u{1b}[10;1H__TUI__\u{1b}[?\(mode)l__SHELL__", in: view)
            XCTAssertFalse(screen(view).contains("__TUI__"))
            XCTAssertTrue(screen(view).contains("__SHELL__"))
        }
    }

    func testHistoricalExitAndPromptInOneFrameDoNotInjectReplies() async {
        let view = view()
        var writes = 0
        view.externalSend = { _, _ in writes += 1; return true }
        view.beginTruncatedRuntimeReplay()
        await receive("\u{1b}[12;1H__STALE__\u{1b}[?1049l__PROMPT__\u{1b}[5n", in: view, historical: true)
        XCTAssertTrue(screen(view).contains("__PROMPT__"))
        XCTAssertFalse(screen(view).contains("__STALE__"))
        XCTAssertEqual(writes, 0)
    }
}
