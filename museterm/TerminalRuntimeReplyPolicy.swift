import Foundation

/// Emulator responses can continue during an AI lease. This path cannot carry
/// printable commands, line breaks, pasted text or arbitrary OSC payloads.
nonisolated enum TerminalRuntimeReplyPolicy {
    private static let maximumBytes = 1_024
    private static let expression = try? NSRegularExpression(pattern:
        "^(?:\u{1b}\\[[0-9;?><]{0,80}[Rcnt]|\u{1b}\\][0-9]{1,2};rgb:[0-9a-fA-F]{1,4}/[0-9a-fA-F]{1,4}/[0-9a-fA-F]{1,4}(?:\u{7}|\u{1b}\\\\)|\u{1b}_Gi=[0-9]{1,10};(?:OK|ENOTSUP)\u{1b}\\\\){1,16}$")

    static func allows(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count <= maximumBytes, let text = String(data: data, encoding: .utf8),
              let expression else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.firstMatch(in: text, range: range)?.range == range
    }
}
