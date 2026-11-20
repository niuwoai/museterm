import Foundation

extension TerminalSession {
    func nativeAgentEnvironment(_ base: [String]) -> [String] {
        let clean = base.filter {
            !$0.hasPrefix("MUSETERM_AGENT_CONTEXT=") && !$0.hasPrefix("QTERM_AGENT_CONTEXT=")
        }
        do {
            let path = try nativeAgentContext.prepare(tabID: id, root: TerminalToolPaths.rootDirectory).path
            // Existing WillDeep releases still consume the legacy environment key.
            return clean + ["MUSETERM_AGENT_CONTEXT=\(path)", "QTERM_AGENT_CONTEXT=\(path)"]
        } catch {
            NSLog("MuseTerm native status context unavailable; terminal remains usable")
            return clean
        }
    }
}
