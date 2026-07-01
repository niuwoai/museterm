import CoreGraphics

struct TerminalSelectionAutoscroll: Equatable {
    enum Direction: Equatable {
        case up
        case down
    }

    let direction: Direction
    let lines: Int

    static let edgeInset: CGFloat = 32
    static let pixelsPerLine: CGFloat = 18
    static let maximumLinesPerTick = 6

    static func action(pointerY: CGFloat, viewHeight: CGFloat) -> TerminalSelectionAutoscroll? {
        guard viewHeight > 0 else { return nil }

        if pointerY >= viewHeight - edgeInset {
            return TerminalSelectionAutoscroll(
                direction: .up,
                lines: lineCount(forDepth: pointerY - (viewHeight - edgeInset))
            )
        }

        if pointerY <= edgeInset {
            return TerminalSelectionAutoscroll(
                direction: .down,
                lines: lineCount(forDepth: edgeInset - pointerY)
            )
        }

        return nil
    }

    private static func lineCount(forDepth depth: CGFloat) -> Int {
        let rawLines = Int(ceil(max(1, depth) / pixelsPerLine))
        return min(maximumLinesPerTick, max(1, rawLines))
    }
}
