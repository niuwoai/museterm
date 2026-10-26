import Foundation

/// Previously rendered bytes reconstruct the view, but must not ring, answer
/// old queries or replay clipboard/command side effects. Bytes produced while
/// the UI was detached remain live, even when delivered in the same frame.
nonisolated enum TerminalRuntimeReplayBoundary {
    static func removingRenderedOverlap(from response: TerminalRuntimeResponse,
                                        renderedThrough boundary: TerminalRuntimeOutputCursor?,
                                        historicalBytes: Int) -> (TerminalRuntimeResponse, Int) {
        guard let cursor = response.cursor, let boundary, cursor.generation == boundary.generation,
              let data = response.data, cursor.offset >= UInt64(data.count) else {
            return (response, historicalBytes)
        }
        let start = cursor.offset - UInt64(data.count)
        let overlap = Int(min(UInt64(data.count), boundary.offset > start ? boundary.offset - start : 0))
        guard overlap > 0 else { return (response, historicalBytes) }
        var trimmed = response
        trimmed.data = Data(data.dropFirst(overlap))
        trimmed.hasGap = false
        return (trimmed, max(0, historicalBytes - overlap))
    }

    static func historicalBytes(in response: TerminalRuntimeResponse,
                                renderedThrough boundary: TerminalRuntimeOutputCursor?) throws -> Int {
        guard let boundary else { return 0 }
        guard let cursor = response.cursor, cursor.generation == boundary.generation else {
            throw TerminalRuntimeConnectionError.serviceChanged
        }
        let count = UInt64(response.data?.count ?? 0)
        guard cursor.offset >= count else { throw TerminalRuntimeConnectionError.invalidResponse }
        let start = cursor.offset - count
        guard boundary.offset > start else { return 0 }
        return Int(min(count, boundary.offset - start))
    }
}
