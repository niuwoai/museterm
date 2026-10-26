import Foundation

/// SwiftTerm emits mouse input through the same delegate as emulator replies.
/// Classifying it here only selects the normal human-input path; it never
/// grants access to the protocol-reply path or bypasses the ownership lock.
nonisolated enum TerminalMouseReportPolicy {
    private static let maximumBytes = 64
    private static let expression = try? NSRegularExpression(pattern:
        "^(?:<[0-9]{1,3};[0-9]{1,8};[0-9]{1,8}[Mm]|[0-9]{1,3};[0-9]{1,8};[0-9]{1,8}M)$")

    static func isMouseReport(_ data: ArraySlice<UInt8>) -> Bool {
        guard data.count <= maximumBytes else { return false }
        let body: ArraySlice<UInt8>
        if data.starts(with: [0x1b, 0x5b]) { body = data.dropFirst(2) }
        else if data.first == 0x9b { body = data.dropFirst() }
        else { return false }
        if body.first == 0x4d {
            let coordinates = body.dropFirst()
            if coordinates.count == 3 { return coordinates.allSatisfy { $0 >= 32 } }
            guard let text = String(bytes: coordinates, encoding: .utf8) else { return false }
            return text.unicodeScalars.count == 3 && text.unicodeScalars.allSatisfy { $0.value >= 32 }
        }
        guard let text = String(bytes: body, encoding: .utf8), let expression else { return false }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.firstMatch(in: text, range: range)?.range == range
    }
}

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
