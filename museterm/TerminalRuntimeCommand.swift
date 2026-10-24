import CryptoKit
import Foundation

/// Shell-marker evidence only. Command text remains in the terminal output, never in this ledger.
nonisolated struct TerminalRuntimeCommandInfo: Codable, Equatable {
    let id: UUID
    let generation: UUID
    let markerOffset: UInt64
    let startedAt: Date
    var endedAt: Date? = nil
    var exitCode: Int32? = nil
    var state: TerminalCommandLifecycleState = .running

    static func identity(generation: UUID, markerOffset: UInt64) -> UUID {
        let digest = SHA256.hash(data: Data("qterm-command-v1:\(generation.uuidString):\(markerOffset)".utf8))
        let bytes = Array(digest.prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

final class TerminalRuntimeCommandLedger {
    struct Evidence {
        let outputStart: UInt64
        var outputEnd: UInt64?
        let isLowInformation: Bool
        var hasErrorSignal = false
    }
    static let maximumCommands = 200
    static let maximumProjectedCommands = 8
    private(set) var commands: [TerminalRuntimeCommandInfo] = []
    private let parser = TerminalShellIntegrationParser()
    private(set) var evidence: [UUID: Evidence] = [:]
    private var activeOutput = Data()
    private var activeOutputParser = TerminalBellParser()
    private static let maximumEvidenceBytes = 16_384

    var snapshots: [UUID: TerminalWaitCommandSnapshot] {
        Dictionary(uniqueKeysWithValues: commands.map {
            ($0.id, .init(finished: $0.endedAt != nil, state: $0.state))
        })
    }

    func accept(_ data: ArraySlice<UInt8>, at offset: UInt64, generation: UUID,
                now: Date = Date()) -> [TerminalRuntimeCommandInfo] {
        var changes: [TerminalRuntimeCommandInfo] = []
        var consumed = 0
        for located in parser.acceptLocated(data, at: offset) {
            let before = located.startOffset > offset ? min(data.count, Int(located.startOffset - offset)) : 0
            appendOutput(data, from: consumed, to: before)
            consumed = max(consumed, min(data.count, Int(located.endOffset - offset)))
            switch located.event {
            case .commandStarted(let text) where !text.isEmpty:
                if let previous = finish(state: .superseded, outputEnd: located.startOffset, now: now) { changes.append(previous) }
                let command = TerminalRuntimeCommandInfo(
                    id: TerminalRuntimeCommandInfo.identity(generation: generation, markerOffset: located.startOffset),
                    generation: generation, markerOffset: located.startOffset, startedAt: now)
                commands.append(command)
                evidence[command.id] = .init(outputStart: located.endOffset,
                    isLowInformation: TerminalReminderPolicy.isLowInformationCommand(text))
                activeOutput.removeAll(keepingCapacity: true)
                activeOutputParser = TerminalBellParser()
                if commands.count > Self.maximumCommands {
                    evidence[commands.removeFirst().id] = nil
                }
                changes.append(command)
            case .commandFinished(let code):
                if let command = finish(state: code == 0 ? .succeeded : .failed, exitCode: code,
                                        outputEnd: located.startOffset, now: now) {
                    changes.append(command)
                }
            default: break
            }
            // A recognized shell OSC has consumed its complete terminator,
            // including when its prefix was already fed in the previous chunk.
            activeOutputParser = TerminalBellParser()
        }
        appendOutput(data, from: consumed, to: data.count)
        return changes
    }

    private func appendOutput(_ bytes: ArraySlice<UInt8>, from start: Int, to end: Int) {
        guard commands.last?.endedAt == nil, !commands.isEmpty, end > start else { return }
        let lower = bytes.index(bytes.startIndex, offsetBy: start)
        let upper = bytes.index(bytes.startIndex, offsetBy: end)
        activeOutput.append(activeOutputParser.consume(bytes[lower..<upper]).visible)
        if activeOutput.count > Self.maximumEvidenceBytes { activeOutput.removeFirst(activeOutput.count - Self.maximumEvidenceBytes) }
    }

    @discardableResult
    func finish(state: TerminalCommandLifecycleState = .completedUnknownStatus,
                exitCode: Int32? = nil, outputEnd: UInt64? = nil, now: Date = Date()) -> TerminalRuntimeCommandInfo? {
        guard let last = commands.indices.last, commands[last].endedAt == nil else { return nil }
        commands[last].endedAt = now
        commands[last].exitCode = exitCode
        commands[last].state = state
        evidence[commands[last].id]?.outputEnd = outputEnd
        let kinds = TerminalOutputInsightAnalyzer.outputSummary(in: String(decoding: activeOutput, as: UTF8.self))?.insightKinds ?? []
        evidence[commands[last].id]?.hasErrorSignal = kinds.contains(.error) || kinds.contains(.stackTrace)
        activeOutput.removeAll(keepingCapacity: true)
        return commands[last]
    }
}
