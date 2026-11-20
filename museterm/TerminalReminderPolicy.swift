import Foundation

/// Inbox eligibility is independent of system notification permission and UI visibility.
nonisolated struct TerminalReminderPolicy: Codable, Equatable {
    var bells = true
    var commandFailures = true
    var longCommandCompletion = true
    var processExits = false
    var longCommandSeconds: Double = 30
    var failureMinimumSeconds: Double = 5

    var isValid: Bool {
        longCommandSeconds.isFinite && longCommandSeconds >= 0
            && failureMinimumSeconds.isFinite && failureMinimumSeconds >= 0
    }

    /// Native lifecycle reports already carry the meaning of an agent's beep.
    /// Unknown/expired agents without an existing semantic item retain ordinary bell fallback.
    func allowsBell(agent: TerminalAgentSnapshot?, hasSemanticItem: Bool) -> Bool {
        guard bells, !hasSemanticItem else { return false }
        guard let agent, agent.source == .integration else { return true }
        return agent.activity == .unknown || agent.activity == .exited
    }

    func allowsCommand(state: TerminalCommandLifecycleState, duration: Double,
                       isLowInformation: Bool, hasErrorSignal: Bool) -> Bool {
        if state == .failed, commandFailures, !isLowInformation {
            return duration >= failureMinimumSeconds || hasErrorSignal
        }
        return state == .succeeded && longCommandCompletion && duration >= longCommandSeconds
    }

    static func isLowInformationCommand(_ command: String) -> Bool {
        let words = command.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return true }
        let wrappers: Set<String> = ["builtin", "command"]
        let index = words.indices.first { !wrappers.contains(words[$0]) } ?? words.startIndex
        let name = URL(fileURLWithPath: words[index]).lastPathComponent
        let ignored: Set<String> = ["alias", "bg", "cd", "clear", "dirs", "disown", "export", "false",
            "fg", "history", "jobs", "popd", "pushd", "pwd", "true", "unalias", "unset"]
        return ignored.contains(name)
    }
}

/// BEL inside an OSC terminates that control string; it is not a terminal bell.
/// DCS/APC/PM/SOS payloads are likewise opaque, even across PTY read boundaries.
final class TerminalBellParser {
    private enum State { case ground, escape, csi, osc, oscEscape, string, stringEscape }
    private var state = State.ground

    func accept(_ bytes: ArraySlice<UInt8>) -> Int {
        consume(bytes).bells
    }

    func consume(_ bytes: ArraySlice<UInt8>) -> (bells: Int, visible: Data) {
        var count = 0
        var visible = Data()
        for byte in bytes {
            switch state {
            case .ground, .csi:
                if byte == 7 { count += 1 }
                else if byte == 27 { state = .escape }
                else if case .csi = state, (0x40...0x7e).contains(byte) { state = .ground }
                else if case .ground = state, byte >= 32 || [9, 10, 13].contains(byte) { visible.append(byte) }
            case .escape:
                switch byte {
                case 7: count += 1
                case 27: break
                case 93: state = .osc
                case 80, 88, 94, 95: state = .string
                case 91: state = .csi
                default: state = .ground
                }
            case .osc:
                if byte == 7 { state = .ground }
                else if byte == 27 { state = .oscEscape }
                else if byte == 24 || byte == 26 { state = .ground }
            case .oscEscape:
                if byte == 92 || byte == 7 { state = .ground }
                else if byte != 27 { state = .osc }
            case .string:
                if byte == 27 { state = .stringEscape }
                else if byte == 24 || byte == 26 { state = .ground }
            case .stringEscape:
                if byte == 92 { state = .ground }
                else if byte != 27 { state = .string }
            }
        }
        return (count, visible)
    }
}
