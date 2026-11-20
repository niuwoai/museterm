import Foundation
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

    /// The live tail of a view whose terminal SwiftTerm keeps internal. The content snapshot
    /// numbers rows in the same scroll-invariant space and ignores where the user has scrolled,
    /// so a scrolled-back viewport is not mistaken for the agent's current screen.
    static func liveTail(_ view: TerminalView) -> String {
        let limit = TerminalAgentScreenRules.maximumLines
        guard let snapshot = view.terminalContentSnapshot(region: .history(maximumScrollbackRows: limit - 1)) else {
            return ""
        }
        let live = snapshot.rows
            .filter { $0.absoluteRow >= snapshot.liveTopRow - (limit - 1) }
            .suffix(limit)
            .map { terminalReplacingNulls($0.text) }
            .joined(separator: "\n")
        return String(live.suffix(TerminalAgentScreenRules.maximumCharacters))
    }
}

/// The snapshot's row text keeps NUL placeholders for unwritten cells. The line translation the
/// headless reader uses drops them, and the two paths have to agree.
private func terminalReplacingNulls(_ text: String) -> String {
    text.replacingOccurrences(of: "\u{0}", with: "")
}
