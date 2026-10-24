import Foundation

/// Owned by the runtime's serial executor. The byte cursor is independent of UI
/// snapshots, Agent event cursors and layout IDs. A gap requires an explicit UI
/// recovery path; replaying a truncated VT stream is not a full screen restore.
nonisolated struct TerminalRuntimeOutputCursor: Codable, Equatable {
    let generation: UUID
    let offset: UInt64
}

nonisolated struct TerminalRuntimeOutputBatch: Equatable {
    let data: Data
    let cursor: TerminalRuntimeOutputCursor
    let latestOffset: UInt64
    let hasGap: Bool
}

nonisolated enum TerminalRuntimeOutputError: Error, Equatable {
    case invalidCapacity, invalidLimit, generationChanged, futureCursor, offsetOverflow
}

nonisolated struct TerminalRuntimeOutputJournal {
    static let defaultCapacity = 1_048_576
    let generation: UUID
    private var storage: Data
    private var endOffset: UInt64 = 0
    private var retained = 0
    private var nextIndex = 0

    init(capacity: Int = Self.defaultCapacity, generation: UUID = UUID()) throws {
        guard capacity > 0, capacity <= Self.defaultCapacity * 16 else {
            throw TerminalRuntimeOutputError.invalidCapacity
        }
        self.generation = generation
        storage = Data(count: capacity)
    }

    var cursor: TerminalRuntimeOutputCursor { .init(generation: generation, offset: endOffset) }
    var retainedBytes: Int { retained }

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
    }

    func read(after requested: TerminalRuntimeOutputCursor?, limit: Int) throws -> TerminalRuntimeOutputBatch {
        guard limit > 0, limit <= storage.count else { throw TerminalRuntimeOutputError.invalidLimit }
        if let requested {
            guard requested.generation == generation else { throw TerminalRuntimeOutputError.generationChanged }
            guard requested.offset <= endOffset else { throw TerminalRuntimeOutputError.futureCursor }
        }
        let base = endOffset - UInt64(retained)
        let requestedOffset = requested?.offset ?? 0
        let startOffset = max(base, requestedOffset)
        let count = Int(min(UInt64(limit), endOffset - startOffset))
        let startIndex = (nextIndex + storage.count - Int(endOffset - startOffset)) % storage.count
        let first = min(count, storage.count - startIndex)
        var bytes = storage.subdata(in: startIndex..<(startIndex + first))
        if first < count { bytes.append(storage.prefix(count - first)) }
        return .init(data: bytes, cursor: .init(generation: generation, offset: startOffset + UInt64(count)),
                     latestOffset: endOffset, hasGap: requestedOffset < base)
    }
}
