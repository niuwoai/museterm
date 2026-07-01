import Foundation

enum TerminalShellIntegrationEvent: Equatable {
    case commandStarted(String)
    case commandFinished(Int32)
}

final class TerminalShellIntegrationParser {
    private static let markerPrefix = "\u{1B}]777;MuseTerm;"
    private static let markerTerminator: Character = "\u{7}"
    private static let maxBufferCharacters = 8_192

    private var buffer = ""

    func accept(_ data: ArraySlice<UInt8>) -> [TerminalShellIntegrationEvent] {
        guard !data.isEmpty else { return [] }
        buffer.append(String(decoding: data, as: UTF8.self))

        var events: [TerminalShellIntegrationEvent] = []
        while let prefixRange = buffer.range(of: Self.markerPrefix) {
            let payloadStart = prefixRange.upperBound
            guard let terminatorIndex = buffer[payloadStart...].firstIndex(of: Self.markerTerminator) else {
                if prefixRange.lowerBound != buffer.startIndex {
                    buffer.removeSubrange(buffer.startIndex..<prefixRange.lowerBound)
                }
                trimBufferIfNeeded()
                return events
            }

            let payload = String(buffer[payloadStart..<terminatorIndex])
            if let event = Self.event(from: payload) {
                events.append(event)
            }
            let removeEnd = buffer.index(after: terminatorIndex)
            buffer.removeSubrange(buffer.startIndex..<removeEnd)
        }

        keepPossiblePrefixTail()
        return events
    }

    private static func event(from payload: String) -> TerminalShellIntegrationEvent? {
        if payload.hasPrefix("start=") {
            let hex = payload.dropFirst("start=".count)
            guard let command = command(fromHex: String(hex)) else { return nil }
            return .commandStarted(command)
        }

        if payload.hasPrefix("end=") {
            let value = payload.dropFirst("end=".count)
            guard let exitCode = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                return nil
            }
            return .commandFinished(exitCode)
        }

        return nil
    }

    private static func command(fromHex hex: String) -> String? {
        let clean = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count.isMultiple(of: 2) else { return nil }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(clean.count / 2)
        var index = clean.startIndex
        while index < clean.endIndex {
            let next = clean.index(index, offsetBy: 2)
            guard let byte = UInt8(clean[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }

        return String(bytes: bytes, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func keepPossiblePrefixTail() {
        let keepCount = Self.markerPrefix.count - 1
        guard buffer.count > keepCount else { return }
        buffer = String(buffer.suffix(keepCount))
    }

    private func trimBufferIfNeeded() {
        guard buffer.count > Self.maxBufferCharacters else { return }
        buffer = String(buffer.suffix(Self.maxBufferCharacters))
    }
}
