import SwiftTerm
import XCTest
@testable import museterm

@MainActor
final class TerminalGalleryTests: XCTestCase {
    func testUnknownOscNumberNeverReachesTheScreen() {
        let delegate = GalleryTerminalDelegate()
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 80, rows: 24))
        let before = screenText(terminal)

        terminal.feed(text: "\u{1b}]7771;v=1;hello;willdeep 0.1\u{7}visible")

        XCTAssertEqual(screenText(terminal).filter { !$0.isWhitespace }, "visible")
        XCTAssertFalse(screenText(terminal).contains("7771"))
    }

    func testAnnouncedListOpensTheColumnAndAnEmptyListClosesIt() {
        let gallery = TerminalGalleryState()
        XCTAssertFalse(gallery.isVisible)

        gallery.receive(Array("v=1;hello;willdeep 0.1".utf8))
        XCTAssertFalse(gallery.isVisible, "A hello without images keeps the full terminal")

        gallery.receive(Array("v=1;list;[{\"id\":\"abc\",\"name\":\"shot.png\",\"mutable\":true}]".utf8))
        XCTAssertTrue(gallery.isVisible)
        XCTAssertEqual(gallery.items.map(\.id), ["abc"])
        XCTAssertTrue(gallery.items[0].canDelete)

        gallery.receive(Array("v=1;list;[]".utf8))
        XCTAssertFalse(gallery.isVisible)
    }

    func testAPasteShowsImmediatelyAndSettlesWhenAcknowledged() {
        let gallery = TerminalGalleryState()
        gallery.receive(Array("v=1;hello;willdeep 0.1".utf8))
        let image = NSImage(size: NSSize(width: 1, height: 1))

        gallery.stagePaste(nonce: "paste1", image: image)
        XCTAssertEqual(gallery.items.map(\.state), [.pending])
        XCTAssertFalse(gallery.items[0].canDelete, "A paste still in flight has no delete icon")

        gallery.receive(Array("v=1;list;[{\"id\":\"final-id\",\"name\":\"clipboard.png\",\"mutable\":true}]".utf8))
        gallery.receive(Array("v=1;ack;paste1;final-id".utf8))

        XCTAssertEqual(gallery.items.map(\.id), ["final-id"])
        XCTAssertEqual(gallery.items[0].image, image)
        XCTAssertTrue(gallery.items[0].canDelete)
    }

    func testRejectKeepsTheThumbnailRemovableWithoutTellingTheProgram() {
        let gallery = TerminalGalleryState()
        gallery.receive(Array("v=1;hello;willdeep 0.1".utf8))
        gallery.stagePaste(nonce: "paste1", image: NSImage(size: NSSize(width: 1, height: 1)))

        gallery.receive(Array("v=1;reject;paste1;limit".utf8))

        XCTAssertTrue(gallery.isVisible)
        guard case .rejected("limit") = gallery.items[0].state else {
            return XCTFail("Expected the refusal to be visible")
        }
        XCTAssertTrue(gallery.items[0].canDelete)
    }

    func testBlobPiecesReassembleIntoTheListedImage() {
        let gallery = TerminalGalleryState()
        gallery.receive(Array("v=1;hello;willdeep 0.1".utf8))
        gallery.receive(Array("v=1;list;[{\"id\":\"gen1\",\"name\":\"generated.png\",\"mutable\":false}]".utf8))
        let png = Data(base64Encoded: Self.onePixelPNG)!
        let encoded = png.base64EncodedString()
        let split = encoded.index(encoded.startIndex, offsetBy: 8)

        gallery.receive(Array("v=1;blob;gen1;0;2;\(encoded[..<split])".utf8))
        XCTAssertNil(gallery.items[0].image)
        gallery.receive(Array("v=1;blob;gen1;1;2;\(encoded[split...])".utf8))

        XCTAssertNotNil(gallery.items[0].image)
        XCTAssertFalse(gallery.items[0].canDelete, "A finished image cannot be deleted")
    }

    func testDropFramesStayInsideOneRuntimeWriteAndCarryNoImageInTheRecord() throws {
        let png = Data(repeating: 0x5a, count: 90_000)
        let outgoing = try XCTUnwrap(TerminalGalleryProtocol.drop(nonce: "abc123", png: png))

        XCTAssertGreaterThan(outgoing.frames.count, 1)
        for frame in outgoing.frames {
            XCTAssertLessThanOrEqual(frame.count, TerminalGalleryProtocol.maximumFrameBytes)
            XCTAssertEqual(frame.prefix(2), [0x1b, 0x5d])
        }
        XCTAssertFalse(outgoing.validationText.contains("Wg"))
        XCTAssertLessThan(outgoing.validationText.count, 64)
    }

    func testFramerReturnsTheBytesAroundAFrameAndHoldsAnUnfinishedOne() {
        var framer = TerminalGalleryFramer()
        let first = framer.push(Array("hi\u{1b}]7771;v=1;hel".utf8)[...], now: 10)
        XCTAssertEqual(String(bytes: first.plain, encoding: .utf8), "hi")
        XCTAssertTrue(first.frames.isEmpty)

        let second = framer.push(Array("lo;willdeep\u{7}".utf8)[...], now: 10.5)
        XCTAssertEqual(second.frames.count, 1)
        XCTAssertTrue(second.plain.isEmpty)

        let third = framer.push(Array("!".utf8)[...], now: 10.6)
        XCTAssertEqual(String(bytes: third.plain, encoding: .utf8), "!")

        var stale = TerminalGalleryFramer()
        _ = stale.push(Array("\u{1b}]7771;v=1;hel".utf8)[...], now: 1)
        let expired = stale.push(Array("\u{1b}[A".utf8)[...], now: 9)
        XCTAssertEqual(expired.plain, Array("\u{1b}[A".utf8))
        let dropped = stale.push(Array("after".utf8)[...], now: 9)
        XCTAssertEqual(String(bytes: dropped.plain, encoding: .utf8), "after")
    }

    func testByeRemovesTheColumn() {
        let gallery = TerminalGalleryState()
        gallery.receive(Array("v=1;hello;willdeep 0.1".utf8))
        gallery.receive(Array("v=1;list;[{\"id\":\"abc\",\"name\":\"shot.png\",\"mutable\":true}]".utf8))

        gallery.receive(Array("v=1;bye;".utf8))

        XCTAssertFalse(gallery.joined)
        XCTAssertFalse(gallery.isVisible)
    }

    private func screenText(_ terminal: Terminal) -> String {
        (0..<terminal.rows).map { terminal.getLine(row: $0)?.translateToString(trimRight: true) ?? "" }
            .joined(separator: "\n")
    }

    private static let onePixelPNG =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
}

private final class GalleryTerminalDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}
