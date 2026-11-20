import XCTest
@testable import museterm

final class TerminalRuntimeCommandTests: XCTestCase {
    private let start = Array("\u{1B}]777;MuseTerm;start=6563686f206f6b\u{7}".utf8)
    private let end = Array("\u{1B}]777;MuseTerm;end=0\u{1B}\\".utf8)

    func testEveryByteSplitPreservesPhysicalMarkerOffsets() {
        let prefix = Array("中文🙂".utf8)
        let bytes = prefix + start + end
        for split in 0...bytes.count {
            let parser = TerminalShellIntegrationParser()
            let events = parser.acceptLocated(bytes[..<split], at: 500)
                + parser.acceptLocated(bytes[split...], at: 500 + UInt64(split))
            XCTAssertEqual(events.map(\.event), [.commandStarted("echo ok"), .commandFinished(0)])
            XCTAssertEqual(events.first?.startOffset, 500 + UInt64(prefix.count))
            XCTAssertEqual(events.last?.endOffset, 500 + UInt64(bytes.count))
        }
    }

    func testDiscontinuityDoesNotCompleteOldPartialMarker() {
        let parser = TerminalShellIntegrationParser()
        XCTAssertTrue(parser.acceptLocated(start.dropLast(), at: 0).isEmpty)
        XCTAssertTrue(parser.acceptLocated(start.suffix(1), at: 100).isEmpty)
        XCTAssertEqual(parser.acceptLocated(end[...], at: 101).map(\.event), [.commandFinished(0)])
    }

    func testMalformedUnterminatedPayloadIsBoundedAndRecovers() {
        let parser = TerminalShellIntegrationParser()
        let bytes = Array("\u{1B}]777;MuseTerm;start=".utf8) + Array(repeating: UInt8(65), count: 100_000)
        XCTAssertTrue(parser.accept(bytes[...]).isEmpty)
        XCTAssertLessThanOrEqual(parser.retainedByteCount, TerminalShellIntegrationParser.maximumRetainedBytes)
        XCTAssertEqual(parser.accept(end[...]), [.commandFinished(0)])
    }

    func testLedgerIdentityMatchesParserAndSeparatesGeneration() throws {
        let ledger = TerminalRuntimeCommandLedger(), generation = UUID()
        let started = try XCTUnwrap(ledger.accept(start[...], at: 22, generation: generation).first)
        XCTAssertEqual(started.id, TerminalRuntimeCommandInfo.identity(generation: generation, markerOffset: 22))
        XCTAssertNotEqual(started.id, TerminalRuntimeCommandInfo.identity(generation: UUID(), markerOffset: 22))
        let finished = try XCTUnwrap(ledger.accept(end[...], at: 22 + UInt64(start.count), generation: generation).first)
        XCTAssertEqual(finished.id, started.id)
        XCTAssertEqual(finished.state, .succeeded)
        XCTAssertEqual(finished.exitCode, 0)
        XCTAssertTrue(ledger.snapshots[started.id]?.finished == true)
        let encoded = String(decoding: try JSONEncoder().encode(ledger.commands), as: UTF8.self)
        XCTAssertFalse(encoded.contains("echo"))
        XCTAssertFalse(encoded.contains("6563686f"))
    }

    func testSupersedingAndExitNeverInventSuccess() throws {
        let ledger = TerminalRuntimeCommandLedger(), generation = UUID()
        let first = try XCTUnwrap(ledger.accept(start[...], at: 0, generation: generation).first)
        let changes = ledger.accept(start[...], at: UInt64(start.count), generation: generation)
        XCTAssertEqual(changes.map(\.state), [.superseded, .running])
        XCTAssertEqual(changes.first?.id, first.id)
        XCTAssertEqual(ledger.finish()?.state, .completedUnknownStatus)
        XCTAssertNil(ledger.finish())
    }

    func testHistoryEvictsOldCommandsAndKeepsActive() throws {
        let ledger = TerminalRuntimeCommandLedger(), generation = UUID()
        let first = try XCTUnwrap(ledger.accept(start[...], at: 0, generation: generation).first)
        for index in 1...TerminalRuntimeCommandLedger.maximumCommands {
            _ = ledger.accept(start[...], at: UInt64(index * start.count), generation: generation)
        }
        XCTAssertEqual(ledger.commands.count, TerminalRuntimeCommandLedger.maximumCommands)
        XCTAssertNil(ledger.snapshots[first.id])
        XCTAssertEqual(ledger.commands.last?.state, .running)
    }

    func testErrorEvidenceIgnoresControlStringsAndKeepsSplitVisibleTail() throws {
        let generation = UUID(), ledger = TerminalRuntimeCommandLedger()
        let hidden = Array("\u{1b}]0;error: hidden title\u{7}\u{1b}Perror: hidden payload\u{1b}\\".utf8)
        var offset = UInt64(0)
        for bytes in [start, hidden, end] {
            _ = ledger.accept(bytes[...], at: offset, generation: generation)
            offset += UInt64(bytes.count)
        }
        let id = try XCTUnwrap(ledger.commands.last?.id)
        XCTAssertFalse(try XCTUnwrap(ledger.evidence[id]).hasErrorSignal)
        let visible = Array("\u{1b}[31merror: visible\u{1b}[0m\n".utf8)
        for bytes in [start, Array(repeating: UInt8(120), count: 32_000), Array(visible.prefix(12)), Array(visible.dropFirst(12)), end] {
            _ = ledger.accept(bytes[...], at: offset, generation: generation)
            offset += UInt64(bytes.count)
        }
        let nextID = try XCTUnwrap(ledger.commands.last?.id)
        XCTAssertTrue(try XCTUnwrap(ledger.evidence[nextID]).hasErrorSignal)
    }
}
