import XCTest
@testable import museterm

@MainActor
final class TerminalRuntimeOutputJournalTests: XCTestCase {
    func testWrappedReplayPreservesEveryByteAndPagedCursor() throws {
        var journal = try TerminalRuntimeOutputJournal(capacity: 8)
        try journal.append(Data("abcde".utf8))
        let first = try journal.read(after: nil, limit: 4)
        XCTAssertEqual(first.data, Data("abcd".utf8))
        XCTAssertFalse(first.hasGap)
        try journal.append(Data("fghij".utf8))
        let next = try journal.read(after: first.cursor, limit: 4)
        XCTAssertEqual(next.data, Data("efgh".utf8))
        XCTAssertFalse(next.hasGap)
        let tail = try journal.read(after: next.cursor, limit: 8)
        XCTAssertEqual(tail.data, Data("ij".utf8))
        XCTAssertEqual(tail.cursor, journal.cursor)
    }

    func testEvictionReportsGapInsteadOfPretendingCompleteHistory() throws {
        var journal = try TerminalRuntimeOutputJournal(capacity: 5)
        let old = journal.cursor
        try journal.append(Data("123".utf8))
        try journal.append(Data("456789".utf8))
        let result = try journal.read(after: old, limit: 5)
        XCTAssertEqual(result.data, Data("56789".utf8))
        XCTAssertTrue(result.hasGap)
        XCTAssertEqual(journal.retainedBytes, 5)
        XCTAssertTrue(try journal.read(after: nil, limit: 5).hasGap)
    }

    func testDifferentProcessGenerationAndFutureOffsetsAreRejected() throws {
        let journal = try TerminalRuntimeOutputJournal(capacity: 4)
        XCTAssertThrowsError(try journal.read(after: .init(generation: UUID(), offset: 0), limit: 4)) {
            XCTAssertEqual($0 as? TerminalRuntimeOutputError, .generationChanged)
        }
        XCTAssertThrowsError(try journal.read(after: .init(generation: journal.generation, offset: 1), limit: 4)) {
            XCTAssertEqual($0 as? TerminalRuntimeOutputError, .futureCursor)
        }
    }

    func testRawVTAndBinaryBytesAreNotDecodedOrRewritten() throws {
        var journal = try TerminalRuntimeOutputJournal(capacity: 16)
        let bytes = Data([0x1b, 0x5b, 0x32, 0x4a, 0x00, 0xff, 0xe4, 0xb8, 0xad])
        try journal.append(bytes)
        XCTAssertEqual(try journal.read(after: nil, limit: 16).data, bytes)
        XCTAssertEqual(try journal.read(after: journal.cursor, limit: 16).data, Data())
    }

    func testCapacityAndRequestLimitsStayBounded() throws {
        XCTAssertThrowsError(try TerminalRuntimeOutputJournal(capacity: 0))
        XCTAssertThrowsError(try TerminalRuntimeOutputJournal(capacity: .max))
        let journal = try TerminalRuntimeOutputJournal(capacity: 2)
        XCTAssertThrowsError(try journal.read(after: nil, limit: 0))
        XCTAssertThrowsError(try journal.read(after: nil, limit: 3))
    }
}
