#if DEBUG
import Foundation

enum TerminalAgentUITestFixture {
    static func applyIfRequested(workspace: TerminalWorkspace) {
        guard ProcessInfo.processInfo.arguments.contains("-ui-testing-agent-state"),
              let tab = workspace.selectedTab, tab.agentStatus == nil else { return }
        if ProcessInfo.processInfo.arguments.contains("-ui-testing-project-workspace") { return }
        if ProcessInfo.processInfo.arguments.contains("-ui-testing-terminal-attention") {
            workspace.newTab()
            // Both callbacks must produce one inbox item and one unread projection.
            for _ in 0..<2 {
                _ = workspace.sessionRegistry.attention.recordTerminal(
                    TerminalAttentionTerminalContext(event: .bell, processRunID: tab.processRunID), tabID: tab.id)
            }
            return
        }
        do {
            let agentTab: TerminalSession
            if ProcessInfo.processInfo.arguments.contains("-ui-testing-sidebar-title") {
                let directory = TerminalToolPaths.rootDirectory.appendingPathComponent("muchtoken", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                agentTab = workspace.newTab(startDirectory: directory.path, profile: TerminalProfile(shell: .bash))
            } else {
                agentTab = tab
            }
            let grant = try agentTab.bindAgent(kind: .codex)
            try agentTab.reportAgent(TerminalAgentReport(instanceID: grant.instanceID, runID: grant.runID,
                token: grant.token, sequence: 1, activity: .blocked, blockReason: .question,
                context: TerminalAgentReportedContext(sessionID: agentTab.id, title: "Fixture task")))
            if ProcessInfo.processInfo.arguments.contains("-ui-testing-agent-detached"), let preferences = workspace.preferences {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    DetachedTerminalPanelManager.shared.detach(tab, workspace: workspace, preferences: preferences)
                }
            }
        } catch {
            NSLog("MuseTerm agent UI fixture could not initialize")
        }
    }
}
#endif
