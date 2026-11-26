import Foundation

/// Owned by the runtime's serial executor. The byte cursor is independent of UI
/// snapshots, Agent event cursors and layout IDs. A gap requires an explicit UI
/// recovery path; replaying a truncated VT stream is not a full screen restore.
nonisolated struct TerminalRuntimeOutputCursor: Codable, Equatable {
    let generation: UUID
    let offset: UInt64
    var gridSequence: UInt64? = nil

    func advances(_ previous: Self?) -> Bool {
        guard let previous, generation == previous.generation else { return true }
        if offset != previous.offset { return offset > previous.offset }
        return (gridSequence ?? 0) > (previous.gridSequence ?? 0)
    }
}

nonisolated struct TerminalRuntimeGrid: Codable, Equatable {
    let columns: Int
    let rows: Int
}

nonisolated struct TerminalRuntimeOutputBatch: Equatable {
    let data: Data
    let cursor: TerminalRuntimeOutputCursor
    let latestOffset: UInt64
    let hasGap: Bool
    var grid: TerminalRuntimeGrid? = nil
}

nonisolated enum TerminalRuntimeOutputError: Error, Equatable {
    case invalidCapacity, invalidLimit, generationChanged, futureCursor, invalidGridCursor, offsetOverflow
}

nonisolated struct TerminalRuntimeOutputJournal {
    static let defaultCapacity = 1_048_576
    static let maximumGridChanges = 256

    private struct GridChange {
        let offset: UInt64
        let sequence: UInt64
        let grid: TerminalRuntimeGrid
    }

    let generation: UUID
    private var storage: Data
    private var endOffset: UInt64 = 0
    private var retained = 0
    private var nextIndex = 0
    private var gridAnchor: GridChange?
    private var gridChanges: [GridChange] = []

    init(capacity: Int = Self.defaultCapacity, generation: UUID = UUID(), initialGrid: TerminalRuntimeGrid? = nil) throws {
        guard capacity > 0, capacity <= Self.defaultCapacity * 16 else {
            throw TerminalRuntimeOutputError.invalidCapacity
        }
        self.generation = generation
        storage = Data(count: capacity)
        gridAnchor = initialGrid.map { GridChange(offset: 0, sequence: 0, grid: $0) }
    }

    var cursor: TerminalRuntimeOutputCursor { head(includingGrid: false) }
    var retainedBytes: Int { retained }

    func head(includingGrid: Bool) -> TerminalRuntimeOutputCursor {
        .init(generation: generation, offset: endOffset,
              gridSequence: includingGrid ? (gridChanges.last ?? gridAnchor)?.sequence : nil)
    }

    mutating func recordResize(_ grid: TerminalRuntimeGrid) {
        guard let previous = gridChanges.last ?? gridAnchor, previous.grid != grid else { return }
        gridChanges.append(.init(offset: endOffset, sequence: previous.sequence + 1, grid: grid))
        trimGridChanges(before: endOffset - UInt64(retained))
    }

    private mutating func trimGridChanges(before offset: UInt64) {
        let evicted = gridChanges.prefix { $0.offset < offset }.count
        let count = max(evicted, gridChanges.count - Self.maximumGridChanges)
        guard count > 0 else { return }
        gridAnchor = gridChanges[count - 1]
        gridChanges.removeFirst(count)
    }

    mutating func append(_ bytes: Data) throws {
        guard !bytes.isEmpty else { return }
        let (newEnd, overflow) = endOffset.addingReportingOverflow(UInt64(bytes.count))
        guard !overflow else { throw TerminalRuntimeOutputError.offsetOverflow }
        let capacity = storage.count
        let suffix = bytes.suffix(capacity)
        // Oversized writes skip a known number of bytes. Place the retained suffix
        // at its absolute ring position so every cursor still maps to the same byte.
        let start = Int((newEnd - UInt64(suffix.count)) % UInt64(capacity))
        storage.withUnsafeMutableBytes { target in
            suffix.withUnsafeBytes { source in
                let first = min(suffix.count, capacity - start)
                target.baseAddress!.advanced(by: start).copyMemory(from: source.baseAddress!, byteCount: first)
                if first < suffix.count {
                    target.baseAddress!.copyMemory(from: source.baseAddress!.advanced(by: first), byteCount: suffix.count - first)
                }
            }
        }
        endOffset = newEnd
        nextIndex = Int(newEnd % UInt64(capacity))
        retained = min(capacity, retained + suffix.count)
        trimGridChanges(before: endOffset - UInt64(retained))
    }

    func read(after requested: TerminalRuntimeOutputCursor?, limit: Int,
              includingGrid: Bool = false) throws -> TerminalRuntimeOutputBatch {
        guard limit > 0, limit <= storage.count else { throw TerminalRuntimeOutputError.invalidLimit }
        if let requested {
            guard requested.generation == generation else { throw TerminalRuntimeOutputError.generationChanged }
            guard requested.offset <= endOffset else { throw TerminalRuntimeOutputError.futureCursor }
        }
        let base = endOffset - UInt64(retained)
        let requestedOffset = requested?.offset ?? 0
        var startOffset = max(base, requestedOffset)
        var stopOffset = endOffset
        var hasGap = requestedOffset < base
        var currentGrid: GridChange?
        if includingGrid, let gridAnchor {
            startOffset = max(startOffset, gridAnchor.offset)
            let sequence = requested?.gridSequence
            let missedGridChange = sequence.map { $0 < gridAnchor.sequence } ?? (gridAnchor.sequence > 0 && requestedOffset <= gridAnchor.offset)
            hasGap = hasGap || requestedOffset < startOffset || missedGridChange
            // A byte gap discards geometry from the missing prefix too. On an
            // ordinary continuation, consume at most one transition at the start
            // of the frame, even if several share the same byte offset.
            let index: Int
            if let sequence, sequence >= gridAnchor.sequence, !hasGap {
                let distance = sequence - gridAnchor.sequence
                guard distance <= UInt64(gridChanges.count) else { throw TerminalRuntimeOutputError.invalidGridCursor }
                index = Int(distance)
                let previous = index == 0 ? gridAnchor : gridChanges[index - 1]
                guard previous.offset <= startOffset,
                      index == gridChanges.count || gridChanges[index].offset >= startOffset else {
                    throw TerminalRuntimeOutputError.invalidGridCursor
                }
            } else {
                index = gridChanges.prefix { $0.offset < startOffset }.count
            }
            let applyNext = index < gridChanges.count && gridChanges[index].offset == startOffset
            let next = index + (applyNext ? 1 : 0)
            currentGrid = next == 0 ? gridAnchor : gridChanges[next - 1]
            if next < gridChanges.count { stopOffset = gridChanges[next].offset }
        }
        let count = Int(min(UInt64(limit), stopOffset - startOffset))
        let startIndex = (nextIndex + storage.count - Int(endOffset - startOffset)) % storage.count
        let first = min(count, storage.count - startIndex)
        var bytes = storage.subdata(in: startIndex..<(startIndex + first))
        if first < count { bytes.append(storage.prefix(count - first)) }
        return .init(data: bytes,
                     cursor: .init(generation: generation, offset: startOffset + UInt64(count), gridSequence: currentGrid?.sequence),
                     latestOffset: endOffset, hasGap: hasGap, grid: currentGrid?.grid)
    }
}
