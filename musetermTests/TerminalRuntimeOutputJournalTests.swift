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

    func testGridAwarePagingPreservesConsecutiveResizesAtTheSameByteOffset() throws {
        let initial = TerminalRuntimeGrid(columns: 80, rows: 24)
        let narrow = TerminalRuntimeGrid(columns: 40, rows: 24)
        let tall = TerminalRuntimeGrid(columns: 80, rows: 35)
        var journal = try TerminalRuntimeOutputJournal(capacity: 16, initialGrid: initial)
        try journal.append(Data("before".utf8))
        journal.recordResize(narrow)
        journal.recordResize(tall)
        try journal.append(Data("after".utf8))

        let first = try journal.read(after: nil, limit: 16, includingGrid: true)
        XCTAssertEqual(first.data, Data("before".utf8))
        XCTAssertEqual(first.grid, initial)
        let next = try journal.read(after: first.cursor, limit: 16, includingGrid: true)
        XCTAssertEqual(next.data, Data())
        XCTAssertEqual(next.grid, narrow)
        XCTAssertEqual(next.cursor.offset, first.cursor.offset)
        XCTAssertTrue(next.cursor.advances(first.cursor))
        let last = try journal.read(after: next.cursor, limit: 16, includingGrid: true)
        XCTAssertEqual(last.data, Data("after".utf8))
        XCTAssertEqual(last.grid, tall)
        XCTAssertEqual(last.cursor, journal.head(includingGrid: true))
        XCTAssertFalse(last.hasGap)
        XCTAssertEqual(try journal.read(after: nil, limit: 16).data, Data("beforeafter".utf8))
    }

    func testTruncationKeepsGridOfFirstRetainedByteAndLeavesByteOnlyReadsIntact() throws {
        let initial = TerminalRuntimeGrid(columns: 80, rows: 24)
        let narrow = TerminalRuntimeGrid(columns: 40, rows: 24)
        let tall = TerminalRuntimeGrid(columns: 80, rows: 35)
        var journal = try TerminalRuntimeOutputJournal(capacity: 6, initialGrid: initial)
        try journal.append(Data("old".utf8))
        journal.recordResize(narrow)
        try journal.append(Data("123456".utf8))
        journal.recordResize(tall)
        try journal.append(Data("end".utf8))
        let first = try journal.read(after: nil, limit: 6, includingGrid: true)
        XCTAssertTrue(first.hasGap)
        XCTAssertEqual(first.grid, narrow)
        XCTAssertEqual(first.data, Data("456".utf8))
        let last = try journal.read(after: first.cursor, limit: 6, includingGrid: true)
        XCTAssertEqual(last.grid, tall)
        XCTAssertEqual(last.data, Data("end".utf8))
        XCTAssertFalse(last.hasGap)

        var compacted = try TerminalRuntimeOutputJournal(capacity: 16, initialGrid: initial)
        try compacted.append(Data("old".utf8))
        for index in 0...TerminalRuntimeOutputJournal.maximumGridChanges {
            compacted.recordResize(index.isMultiple(of: 2) ? narrow : tall)
        }
        try compacted.append(Data("new".utf8))
        let restart = try compacted.read(after: nil, limit: 16, includingGrid: true)
        XCTAssertTrue(restart.hasGap)
        XCTAssertEqual(restart.cursor.offset, 3)
        XCTAssertEqual(restart.grid, tall)
        let byteOnly = try compacted.read(after: nil, limit: 16)
        XCTAssertFalse(byteOnly.hasGap)
        XCTAssertEqual(byteOnly.data, Data("oldnew".utf8))
    }

    func testCapacityAndRequestLimitsStayBounded() throws {
        XCTAssertThrowsError(try TerminalRuntimeOutputJournal(capacity: 0))
        XCTAssertThrowsError(try TerminalRuntimeOutputJournal(capacity: .max))
        let journal = try TerminalRuntimeOutputJournal(capacity: 2)
        XCTAssertThrowsError(try journal.read(after: nil, limit: 0))
        XCTAssertThrowsError(try journal.read(after: nil, limit: 3))
    }
}
