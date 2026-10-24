import Foundation

extension TerminalSession {
    func nativeAgentEnvironment(_ base: [String]) -> [String] {
        let clean = base.filter { !$0.hasPrefix("QTERM_AGENT_CONTEXT=") }
        do {
            return clean + ["QTERM_AGENT_CONTEXT=\(try nativeAgentContext.prepare(tabID: id, root: TerminalToolPaths.rootDirectory).path)"]
        } catch {
            NSLog("QTerm native status context unavailable; terminal remains usable")
            return clean
        }
    }
}
