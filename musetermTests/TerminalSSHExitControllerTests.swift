import AppKit
import SwiftTerm
import XCTest
@testable import museterm

@MainActor
final class TerminalSSHExitControllerTests: XCTestCase {
    func testSSHExitRestoresCurrentUserCursorPreferences() throws {
        let domain = "museterm-ssh-exit-cursor-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let preferences = TerminalPreferences(defaults: defaults)
        let cases: [(TerminalCursorShape, Bool, CursorStyle)] = [
            (.bar, false, .steadyBar), (.bar, true, .blinkBar),
            (.underline, false, .steadyUnderline), (.underline, true, .blinkUnderline)
        ]
        for (shape, blink, expected) in cases {
            preferences.cursorShape = shape
            preferences.cursorBlink = blink
            let session = TerminalSession(sequence: 1, launchConfiguration: .ssh(.init(
                name: "cursor-reset", host: "invalid.test", automaticReconnectEnabled: false)))
            let controller = session.controller
            let view = try XCTUnwrap(controller.container.subviews.compactMap { $0 as? FocusableLocalProcessTerminalView }.first)
            view.externalIsRunning = { false }
            controller.apply(preferences: preferences)
            view.feed(text: "\u{1b}[?1049h\u{1b}[2 q")
            controller.processTerminated(source: view, exitCode: 255)
            XCTAssertEqual(view.terminalStateSnapshot().cursorStyle, expected)
            // An unchanged preference signature must not hide a bad exit reset.
            controller.apply(preferences: preferences)
            XCTAssertEqual(view.terminalStateSnapshot().cursorStyle, expected)
        }
    }

    func testSSHExitKeepsDiagnosticOutsideUnfinishedNormalScreenControls() async throws {
        for partial in [
            "\u{1b}]0;unfinished", "\u{1b}_unfinished", "\u{1b}Pqunfinished",
            "\u{009d}0;unfinished", "\u{009f}unfinished", "\u{0090}qunfinished"
        ] {
            let session = TerminalSession(sequence: 1, launchConfiguration: .ssh(.init(
                name: "normal-diagnostic-reset", host: "invalid.test", automaticReconnectEnabled: false)))
            let controller = session.controller
            let view = try XCTUnwrap(controller.container.subviews.compactMap { $0 as? FocusableLocalProcessTerminalView }.first)
            var running = true
            view.externalIsRunning = { running }
            let parsed = expectation(description: "normal output with incomplete control parsed")
            view.receiveExternal(Data(("__NORMAL_HISTORY__\r\nConnection timed out\r\n" + partial).utf8)) { parsed.fulfill() }
            await fulfillment(of: [parsed], timeout: 5)
            running = false
            controller.processTerminated(source: view, exitCode: 255)
            let history = String(decoding: view.getBufferAsData(kind: .normal), as: UTF8.self)
            XCTAssertTrue(history.contains("__NORMAL_HISTORY__"))
            let diagnostic = history.filter { !$0.isWhitespace }
            XCTAssertTrue(diagnostic.contains(SSHConnectionIssueKind.connectionTimedOut.summary.filter { !$0.isWhitespace }), "\(partial.debugDescription): \(diagnostic)")
            XCTAssertTrue(diagnostic.contains(SSHConnectionIssueKind.connectionTimedOut.suggestion.filter { !$0.isWhitespace }), "\(partial.debugDescription): \(diagnostic)")
            XCTAssertEqual(view.terminalInputStateSnapshot()?.isAlternateBuffer, false)
            view.feed(text: "__AFTER_DIAGNOSTIC__")
            let after = String(decoding: view.getBufferAsData(kind: .normal), as: UTF8.self)
            XCTAssertTrue(after.filter { !$0.isWhitespace }.contains("__AFTER_DIAGNOSTIC__"))
        }
    }

    func testSSHExitDisplaysPendingDiagnosticAfterRestoringNormalScreen() async throws {
        for runningDuringParse in [false, true] {
            let session = TerminalSession(sequence: 1, launchConfiguration: .ssh(.init(
                name: "diagnostic-reset", host: "invalid.test", automaticReconnectEnabled: false)))
            let controller = session.controller
            let view = try XCTUnwrap(controller.container.subviews.compactMap { $0 as? FocusableLocalProcessTerminalView }.first)
            var running = runningDuringParse
            view.externalIsRunning = { running }
            let parsed = expectation(description: "final SSH output parsed")
            let bytes = "__NORMAL_HISTORY__\r\n\u{1b}[?1049h\u{1b}[H__TUI__\r\nConnection timed out"
            view.receiveExternal(Data(bytes.utf8)) { parsed.fulfill() }
            await fulfillment(of: [parsed], timeout: 5)
            XCTAssertTrue(view.terminalInputStateSnapshot()?.isAlternateBuffer == true)
            running = false
            controller.processTerminated(source: view, exitCode: 255)
            let history = String(decoding: view.getBufferAsData(kind: .normal), as: UTF8.self)
            XCTAssertTrue(history.contains("__NORMAL_HISTORY__"))
            XCTAssertFalse(history.contains("__TUI__"))
            let diagnostic = history.filter { !$0.isWhitespace }
            XCTAssertTrue(diagnostic.contains(SSHConnectionIssueKind.connectionTimedOut.summary.filter { !$0.isWhitespace }))
            XCTAssertTrue(diagnostic.contains(SSHConnectionIssueKind.connectionTimedOut.suggestion.filter { !$0.isWhitespace }))
            XCTAssertTrue(view.terminalInputStateSnapshot()?.isAlternateBuffer == false)
        }
    }
}
