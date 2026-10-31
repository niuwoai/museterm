import AppKit
import SwiftTerm
import XCTest
@testable import museterm

@MainActor
final class TerminalMouseInputTests: XCTestCase {
    func testSupportedMouseReportsAreNotPrivilegedReplies() {
        let reports = [
            Array("\u{1b}[<0;12;34M".utf8), Array("\u{1b}[<0;12;34m".utf8),
            Array("\u{1b}[<64;12;34M".utf8), Array("\u{1b}[<65;12;34M".utf8),
            Array("\u{1b}[<32;12;34M".utf8), Array("\u{1b}[32;12;34M".utf8),
            [0x1b, 0x5b, 0x4d, 32, 255, 127], Array("\u{1b}[M \u{100}\u{101}".utf8),
            [0x9b] + Array("<64;12;34M".utf8)
        ]
        for bytes in reports {
            XCTAssertTrue(TerminalMouseReportPolicy.isMouseReport(bytes[...]), "\(bytes)")
            XCTAssertFalse(TerminalRuntimeReplyPolicy.allows(Data(bytes)))
        }
    }

    func testRepliesAndMalformedReportsDoNotBecomeMouseInput() {
        for text in ["", "text", "\u{1b}[0n", "\u{1b}[12;34R", "\u{1b}[?62;1;2c",
                     "\u{1b}[<0;1;2M\n", "\u{1b}[<0;1;2Mtext", "\u{1b}[<0;1M",
                     "\u{1b}[M  ", "\u{1b}[M \n ", "\u{1b}[<0;1;2M\u{1b}[0n"] {
            XCTAssertFalse(TerminalMouseReportPolicy.isMouseReport(Array(text.utf8)[...]))
        }
    }

    func testActualSwiftTermMouseEncodingsUseHumanInput() throws {
        // The emulator no longer exposes the terminal that encodes mouse reports, so the
        // encodings are exercised through the view's own click and scroll handling.
        for mode in [9, 1005, 1006, 1015, 1016] {
            let view = FocusableLocalProcessTerminalView(frame: .init(x: 0, y: 0, width: 800, height: 600))
            let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            defer { window.close() }
            var inputs: [[UInt8]] = []
            view.externalSend = { bytes, protocolTraffic in
                XCTAssertFalse(protocolTraffic, "Mouse mode \(mode) must obey human ownership")
                inputs.append(bytes)
                return true
            }
            view.feed(text: "\u{1b}[?1000h\u{1b}[?\(mode)h")
            let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .init(x: 40, y: 40),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 1))
            view.mouseDown(with: click)
            // A scroll event cannot be built with a scroll distance, so the wheel report is sent
            // the way the view sends one: encoded for the cell under the pointer, then delivered.
            view.sendMouseEvent(button: 4, release: false, col: 4, row: 5)
            XCTAssertGreaterThanOrEqual(inputs.count, 2, "Mouse mode \(mode)")
            XCTAssertTrue(inputs.allSatisfy { TerminalMouseReportPolicy.isMouseReport($0[...]) }, "Mouse mode \(mode)")
        }
    }

    func testActualAppKitClickAndScrollUseHumanInput() throws {
        let view = FocusableLocalProcessTerminalView(frame: .init(x: 0, y: 0, width: 800, height: 600))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        var inputs: [[UInt8]] = []
        view.externalSend = { bytes, protocolTraffic in
            XCTAssertFalse(protocolTraffic)
            inputs.append(bytes)
            return true
        }
        view.feed(text: "\u{1b}[?1000h\u{1b}[?1006h")
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .init(x: 100, y: 100),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1))
        view.mouseDown(with: click)
        XCTAssertEqual(inputs.count, 1)
        XCTAssertTrue(String(decoding: inputs[0], as: UTF8.self).hasPrefix("\u{1b}[<0;"))
        for delta in [4, 5] {
            let previous = inputs.count
            view.sendMouseEvent(button: delta, release: false, col: 4, row: 5)
            XCTAssertGreaterThan(inputs.count, previous)
            let button = delta == 4 ? 64 : 65
            XCTAssertTrue(inputs.dropFirst(previous).allSatisfy {
                String(decoding: $0, as: UTF8.self).hasPrefix("\u{1b}[<\(button);")
            })
        }
    }

    func testRejectedHumanMouseInputDoesNotFallBackToReplyChannel() throws {
        let view = FocusableLocalProcessTerminalView(frame: .init(x: 0, y: 0, width: 800, height: 600))
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        var calls = 0
        var committed = 0
        view.onProcessInputSent = { committed += 1 }
        view.externalSend = { _, protocolTraffic in
            calls += 1
            XCTAssertFalse(protocolTraffic)
            return false
        }
        view.feed(text: "\u{1b}[?1000h\u{1b}[?1006h")
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .init(x: 40, y: 40),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1))
        view.mouseDown(with: click)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(committed, 0)
        XCTAssertFalse(view.didSendLastInput)
    }

    func testDeviceStatusReplyStillUsesProtocolChannel() {
        let view = FocusableLocalProcessTerminalView(frame: .init(x: 0, y: 0, width: 800, height: 600))
        var replies: [Data] = []
        view.externalSend = { bytes, protocolTraffic in
            XCTAssertTrue(protocolTraffic)
            replies.append(Data(bytes))
            return true
        }
        view.feed(text: "\u{1b}[5n")
        XCTAssertEqual(replies, [Data("\u{1b}[0n".utf8)])
    }
}
