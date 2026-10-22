#if DEBUG
import Foundation

enum TerminalAgentUITestFixture {
    static func applyIfRequested(workspace: TerminalWorkspace) {
        guard ProcessInfo.processInfo.arguments.contains("-ui-testing-agent-state"),
              let tab = workspace.selectedTab, tab.agentStatus == nil else { return }
        do {
            let grant = try tab.bindAgent(kind: .codex)
            try tab.reportAgent(TerminalAgentReport(instanceID: grant.instanceID, runID: grant.runID,
                token: grant.token, sequence: 1, activity: .blocked, blockReason: .question))
            if ProcessInfo.processInfo.arguments.contains("-ui-testing-agent-detached"), let preferences = workspace.preferences {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    DetachedTerminalPanelManager.shared.detach(tab, workspace: workspace, preferences: preferences)
                }
            }
        } catch {
            NSLog("QTerm agent UI fixture could not initialize")
        }
    }
}
#endif
