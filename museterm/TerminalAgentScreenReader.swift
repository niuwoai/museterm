import SwiftTerm

enum TerminalAgentScreenReader {
    /// Locate the live end through bounded indexed lookups. getLine(row:) follows yDisp and
    /// would classify old history when the user scrolls; copying the whole history is expensive.
    static func liveTail(_ terminal: Terminal) -> String {
        let start = terminal.buffer.totalLinesTrimmed
        var low = start
        var distance = max(1, terminal.rows)
        var high = start + distance
        while terminal.getScrollInvariantLine(row: high) != nil {
            low = high
            distance *= 2
            high = start + distance
        }
        while low + 1 < high {
            let middle = low + (high - low) / 2
            if terminal.getScrollInvariantLine(row: middle) == nil { high = middle }
            else { low = middle }
        }
        let first = max(start, high - min(terminal.rows, TerminalAgentScreenRules.maximumLines))
        let text = (first..<high).compactMap {
            terminal.getScrollInvariantLine(row: $0)?.translateToString(trimRight: true)
        }.joined(separator: "\n")
        return String(text.suffix(TerminalAgentScreenRules.maximumCharacters))
    }
}
