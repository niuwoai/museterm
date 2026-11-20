import Foundation

nonisolated enum TerminalShellIntegrationEvent: Equatable {
    case commandStarted(String)
    case commandFinished(Int32)
    case shellDetected(String)
    case executionContext(TerminalShellReportedContext)
}

nonisolated struct TerminalLocatedShellEvent: Equatable {
    let event: TerminalShellIntegrationEvent
    let startOffset: UInt64
    let endOffset: UInt64
}

final class TerminalShellIntegrationParser {
    private static let markerPrefix = Data("\u{1B}]777;MuseTerm;".utf8)
    private static let bellTerminator = Data([7])
    private static let stringTerminator = Data([27, 92])
    static let maximumRetainedBytes = 32_768
    private var buffer = Data()
    private var bufferOffset: UInt64 = 0
    private var nextOffset: UInt64?
    var retainedByteCount: Int { buffer.count }

    func accept(_ data: ArraySlice<UInt8>) -> [TerminalShellIntegrationEvent] {
        acceptLocated(data, at: nextOffset ?? 0).map(\.event)
    }

    func acceptLocated(_ data: ArraySlice<UInt8>, at offset: UInt64) -> [TerminalLocatedShellEvent] {
        guard !data.isEmpty else { return [] }
        let (end, overflow) = offset.addingReportingOverflow(UInt64(data.count))
        guard !overflow else { buffer.removeAll(); nextOffset = nil; return [] }
        if nextOffset != offset { buffer.removeAll(); bufferOffset = offset }
        if buffer.isEmpty { bufferOffset = offset }
        nextOffset = end
        buffer.append(contentsOf: data)
        var events: [TerminalLocatedShellEvent] = []
        while let prefixRange = buffer.range(of: Self.markerPrefix) {
            let payloadStart = prefixRange.upperBound
            guard let terminator = Self.terminatorRange(in: buffer, from: payloadStart) else {
                discard(prefixRange.lowerBound)
                if buffer.count > Self.maximumRetainedBytes { discard(buffer.count - Self.maximumRetainedBytes) }
                return events
            }
            let payload = buffer[payloadStart..<terminator.lowerBound]
            if payload.count <= Self.maximumRetainedBytes,
               let text = String(data: payload, encoding: .utf8), let event = Self.event(from: text) {
                events.append(.init(event: event, startOffset: bufferOffset + UInt64(prefixRange.lowerBound),
                    endOffset: bufferOffset + UInt64(terminator.upperBound)))
            }
            discard(terminator.upperBound)
        }
        discard(max(0, buffer.count - (Self.markerPrefix.count - 1)))
        return events
    }

    private func discard(_ count: Int) {
        guard count > 0 else { return }
        buffer = Data(buffer.dropFirst(count))
        bufferOffset += UInt64(count)
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

        if payload.hasPrefix("shell=") {
            let value = payload.dropFirst("shell=".count)
            let shell = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !shell.isEmpty else { return nil }
            return .shellDetected(shell)
        }

        if payload.hasPrefix("context=") {
            let value = String(payload.dropFirst("context=".count))
            let fields = value.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 5 else { return nil }
            let context = TerminalShellReportedContext(
                workingDirectory: text(fromHex: fields[0]),
                user: text(fromHex: fields[1]),
                uid: Int(fields[2]),
                host: text(fromHex: fields[3]),
                shell: text(fromHex: fields[4])
            )
            return context.isEmpty ? nil : .executionContext(context)
        }

        return nil
    }

    private static func terminatorRange(in buffer: Data, from start: Int) -> Range<Int>? {
        let range = start..<buffer.count
        let bell = buffer.range(of: bellTerminator, in: range)
        let st = buffer.range(of: stringTerminator, in: range)
        return [bell, st].compactMap { $0 }.min { $0.lowerBound < $1.lowerBound }
    }

    private static func command(fromHex hex: String) -> String? {
        text(fromHex: hex)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func text(fromHex hex: String) -> String? {
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

        return String(bytes: bytes, encoding: .utf8)
    }

}
