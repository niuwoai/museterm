import Darwin
import Foundation

enum TerminalProjectOperation: String, Codable, CaseIterable {
    case list, createProject, renameProject, createTab, split, moveTerminal, moveTab
    case reorderProjects, reorderTabs, resizeSplit, focus, closeTerminal, closeTab, closeProject
}

struct TerminalProjectToolRequest: Codable {
    let operation: TerminalProjectOperation
    var projectID: UUID? = nil
    var layoutTabID: UUID? = nil
    var terminalID: UUID? = nil
    var splitID: UUID? = nil
    var name: String? = nil
    var directory: String? = nil
    var axis: TerminalSplitAxis? = nil
    var ratio: Double? = nil
    var order: [UUID]? = nil
    var focus: Bool? = nil
    var terminateRunning: Bool? = nil
    var workspaceID: UUID? = nil
    var expectedEpoch: UUID? = nil
    var expectedRevision: UInt64? = nil
    var uiEpoch: UUID? = nil
    var deadlineMonotonic: Double? = nil
}

struct TerminalProjectToolResult: Codable {
    var schemaVersion = 1
    let operation: TerminalProjectOperation
    let workspaceID: UUID
    let appEpoch: UUID
    let revision: UInt64
    let layout: TerminalProjectLayout
    var activities: [String: TerminalProjectActivity] = [:]
    var projectID: UUID? = nil
    var layoutTabID: UUID? = nil
    var terminalID: UUID? = nil
    var removedTerminalIDs: [UUID]? = nil
    // Removing a layout queues explicit process closure. It does not certify a backend ACK.
    var processClosure: String? = nil
    var terminalState: String? = nil
}

private enum TerminalProjectToolError: String, Error {
    case invalidRequest = "invalid_project_request", unavailable = "project_target_unavailable"
    case accessDenied = "project_access_denied", staleLayout = "project_layout_changed"
    case runningConfirmationRequired = "terminate_running_required", capacityExceeded = "project_capacity_exceeded"
    case expired = "project_request_expired"
}

enum TerminalProjectToolService {
    static let action = "project_layout"
    private static let maximumProjects = 64
    private static let maximumTerminals = 64
    private static let maximumRequestLifetime: Double = 60
    private static let nanosecondsPerSecond: Double = 1_000_000_000

    static func requestMonotonicTime() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / nanosecondsPerSecond
    }

    static func perform(_ request: TerminalToolRequest, workspace: TerminalWorkspace, snapshotSequence: Int,
                        authorized: () -> Bool) -> TerminalToolResponse {
        do {
            guard let input = request.projectRequest else { throw TerminalProjectToolError.invalidRequest }
            if input.operation != .list, !authorized() { throw TerminalProjectToolError.accessDenied }
            try validateScope(input, workspace: workspace)
            try workspace.projectLayout.validate()
            let outcome = try execute(input, workspace: workspace)
            try workspace.projectLayout.validate()
            var response = TerminalToolResponse(id: request.id, ok: true, snapshotSequence: snapshotSequence,
                action: action, tabID: outcome.terminalID?.uuidString, message: nil, error: nil)
            response.projectResult = outcome
            return response
        } catch {
            let code: String
            if let failure = error as? TerminalProjectToolError { code = failure.rawValue }
            else if case TerminalProjectLayoutError.invalidName = error { code = "invalid_project_name" }
            else { code = "invalid_project_layout" }
            return TerminalToolResponse(id: request.id, ok: false, snapshotSequence: snapshotSequence,
                action: action, message: nil, error: code)
        }
    }

    private static func validateScope(_ input: TerminalProjectToolRequest, workspace: TerminalWorkspace) throws {
        guard let deadline = input.deadlineMonotonic, deadline.isFinite,
              let epoch = input.uiEpoch else { throw TerminalProjectToolError.invalidRequest }
        let uptime = requestMonotonicTime()
        guard deadline > uptime else { throw TerminalProjectToolError.expired }
        guard deadline - uptime <= maximumRequestLifetime else { throw TerminalProjectToolError.invalidRequest }
        guard epoch == workspace.sessionRegistry.events.appEpoch else { throw TerminalProjectToolError.staleLayout }
        if let id = input.workspaceID, id != workspace.runtimeWorkspaceID { throw TerminalProjectToolError.unavailable }
        if input.expectedEpoch != nil || input.expectedRevision != nil {
            guard input.expectedEpoch == workspace.sessionRegistry.events.appEpoch,
                  input.expectedRevision == workspace.projectLayoutRevision else { throw TerminalProjectToolError.staleLayout }
        }
        if let directory = input.directory {
            guard directory.hasPrefix("/"), !directory.utf8.contains(0),
                  TerminalWorkingDirectory.normalizedExistingDirectory(directory) != nil else {
                throw TerminalProjectToolError.invalidRequest
            }
        }
        if let name = input.name {
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 120,
                  !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw TerminalProjectToolError.invalidRequest
            }
        }
    }

    private static func execute(_ input: TerminalProjectToolRequest, workspace: TerminalWorkspace) throws -> TerminalProjectToolResult {
        if input.operation == .list { return result(input, workspace: workspace) }
        let selection = Selection(workspace)
        let previousSuppression = workspace.suppressAttentionAutoRead
        workspace.suppressAttentionAutoRead = true
        defer { workspace.suppressAttentionAutoRead = previousSuppression }
        var terminal: UUID?, project: UUID?, layoutTab: UUID?, removed: [UUID]?
        switch input.operation {
        case .list: break
        case .createProject:
            guard workspace.projectLayout.projects.count < maximumProjects else { throw TerminalProjectToolError.capacityExceeded }
            try reserveTerminal(workspace)
            guard let name = input.name else { throw TerminalProjectToolError.invalidRequest }
            project = try workspace.createProject(name: name, directory: input.directory)
            terminal = workspace.selectedID
        case .renameProject:
            guard let id = input.projectID, let name = input.name else { throw TerminalProjectToolError.invalidRequest }
            try workspace.renameProject(id, name: name)
            project = id
        case .createTab:
            try reserveTerminal(workspace)
            guard let id = input.projectID, let target = workspace.projectLayout.projects.first(where: { $0.id == id }) else {
                throw TerminalProjectToolError.unavailable
            }
            let directory = input.directory ?? (target.tabs.isEmpty ? target.directory : nil)
            if let directory, TerminalWorkingDirectory.normalizedExistingDirectory(directory) == nil {
                throw TerminalProjectToolError.invalidRequest
            }
            workspace.projectLayout.selectedProjectID = id
            workspace.selectedID = workspace.projectLayout.focusedTerminalID
            terminal = workspace.newTab(startDirectory: directory).id
            project = id
        case .split:
            try reserveTerminal(workspace)
            guard let id = input.terminalID, let axis = input.axis else { throw TerminalProjectToolError.invalidRequest }
            terminal = try workspace.splitTerminal(id, axis: axis).id
        case .moveTerminal:
            guard let id = input.terminalID, let destination = input.projectID else { throw TerminalProjectToolError.invalidRequest }
            try workspace.moveTerminal(id, to: destination)
            terminal = id; project = destination
        case .moveTab:
            try moveTab(input, workspace: workspace)
            project = input.projectID; layoutTab = input.layoutTabID
        case .reorderProjects:
            guard let order = input.order, Set(order).count == order.count,
                  Set(order) == Set(workspace.projectLayout.projects.map(\.id)) else { throw TerminalProjectToolError.invalidRequest }
            let indexed = Dictionary(uniqueKeysWithValues: workspace.projectLayout.projects.map { ($0.id, $0) })
            workspace.projectLayout.projects = order.compactMap { indexed[$0] }
        case .reorderTabs:
            guard let id = input.projectID, let index = workspace.projectLayout.projects.firstIndex(where: { $0.id == id }),
                  let order = input.order, Set(order).count == order.count,
                  Set(order) == Set(workspace.projectLayout.projects[index].tabs.map(\.id)) else {
                throw TerminalProjectToolError.invalidRequest
            }
            let indexed = Dictionary(uniqueKeysWithValues: workspace.projectLayout.projects[index].tabs.map { ($0.id, $0) })
            workspace.projectLayout.projects[index].tabs = order.compactMap { indexed[$0] }
            project = id
        case .resizeSplit:
            guard let id = input.splitID, let ratio = input.ratio, ratio.isFinite, (0.1...0.9).contains(ratio) else {
                throw TerminalProjectToolError.invalidRequest
            }
            try workspace.projectLayout.resize(splitID: id, ratio: ratio)
        case .focus:
            try focus(input, workspace: workspace)
        case .closeTerminal, .closeTab, .closeProject:
            removed = try close(input, workspace: workspace)
        }
        if input.focus != true && input.operation != .focus { selection.restore(workspace) }
        else if let id = workspace.selectedID { workspace.sessionRegistry.attention.markViewed(tabID: id) }
        if let id = terminal, let location = workspace.projectLayout.location(of: id) {
            project = workspace.projectLayout.projects[location.0].id
            layoutTab = workspace.projectLayout.projects[location.0].tabs[location.1].id
        }
        var value = result(input, workspace: workspace)
        value.terminalID = terminal; value.projectID = project; value.layoutTabID = layoutTab
        if let terminal, let session = workspace.sessionRegistry.sessions[terminal] {
            let connected = session.runtimeInfo == nil || session.controller.runtimeHandle?.connected == true
            value.terminalState = session.hasRunningProcess && connected ? "running" : "not_ready"
        }
        value.removedTerminalIDs = removed
        if removed != nil { value.processClosure = "requested" }
        return value
    }

    private static func reserveTerminal(_ workspace: TerminalWorkspace) throws {
        guard workspace.projectLayout.terminalIDs.count < maximumTerminals else { throw TerminalProjectToolError.capacityExceeded }
    }

    private static func result(_ input: TerminalProjectToolRequest, workspace: TerminalWorkspace) -> TerminalProjectToolResult {
        let agents = Dictionary(uniqueKeysWithValues: workspace.sessionRegistry.sessions.values.compactMap { session in
            session.agentStatus.map { (session.id, $0) }
        })
        var value = TerminalProjectToolResult(operation: input.operation, workspaceID: workspace.runtimeWorkspaceID,
            appEpoch: workspace.sessionRegistry.events.appEpoch, revision: workspace.projectLayoutRevision, layout: workspace.projectLayout)
        value.activities = Dictionary(uniqueKeysWithValues: workspace.projectLayout.projects.map {
            ($0.id.uuidString, TerminalProjectActivity(project: $0, agents: agents, attention: workspace.sessionRegistry.attention.activeItems))
        })
        return value
    }

    private static func moveTab(_ input: TerminalProjectToolRequest, workspace: TerminalWorkspace) throws {
        guard let id = input.layoutTabID, let destination = input.projectID,
              let source = workspace.projectLayout.projects.firstIndex(where: { $0.tabs.contains { $0.id == id } }),
              let target = workspace.projectLayout.projects.firstIndex(where: { $0.id == destination }),
              let index = workspace.projectLayout.projects[source].tabs.firstIndex(where: { $0.id == id }) else {
            throw TerminalProjectToolError.unavailable
        }
        if source == target { return }
        let tab = workspace.projectLayout.projects[source].tabs.remove(at: index)
        if workspace.projectLayout.projects[source].selectedTabID == id {
            workspace.projectLayout.projects[source].selectedTabID = workspace.projectLayout.projects[source].tabs.first?.id
        }
        workspace.projectLayout.projects[target].tabs.append(tab)
        workspace.projectLayout.projects[target].selectedTabID = id
        if input.focus == true { workspace.selectProject(destination) }
    }

    private static func focus(_ input: TerminalProjectToolRequest, workspace: TerminalWorkspace) throws {
        if let terminal = input.terminalID {
            guard workspace.projectLayout.location(of: terminal) != nil else { throw TerminalProjectToolError.unavailable }
            try workspace.projectLayout.select(terminal: terminal)
            workspace.selectProject(workspace.projectLayout.selectedProjectID!)
        } else if let tab = input.layoutTabID,
                  let project = workspace.projectLayout.projects.first(where: { $0.tabs.contains { $0.id == tab } }),
                  let leaf = project.tabs.first(where: { $0.id == tab })?.focusedTerminalID {
            try workspace.projectLayout.select(terminal: leaf)
            workspace.selectProject(project.id)
        } else if let project = input.projectID, workspace.projectLayout.projects.contains(where: { $0.id == project }) {
            workspace.selectProject(project)
        } else { throw TerminalProjectToolError.unavailable }
    }

    private static func close(_ input: TerminalProjectToolRequest, workspace: TerminalWorkspace) throws -> [UUID] {
        let ids: [UUID]
        switch input.operation {
        case .closeProject:
            guard let id = input.projectID, let project = workspace.projectLayout.projects.first(where: { $0.id == id }) else {
                throw TerminalProjectToolError.unavailable
            }
            ids = project.tabs.flatMap { $0.layout.terminalIDs }
        case .closeTab:
            guard let id = input.layoutTabID, let tab = workspace.projectLayout.projects.flatMap(\.tabs).first(where: { $0.id == id }) else {
                throw TerminalProjectToolError.unavailable
            }
            ids = tab.layout.terminalIDs
        default:
            guard let id = input.terminalID, workspace.projectLayout.location(of: id) != nil else { throw TerminalProjectToolError.unavailable }
            ids = [id]
        }
        let sessions = try ids.map { id in
            guard let session = workspace.sessionRegistry.sessions[id] else { throw TerminalProjectToolError.unavailable }
            return session
        }
        if sessions.contains(where: \.hasRunningProcess), input.terminateRunning != true {
            throw TerminalProjectToolError.runningConfirmationRequired
        }
        switch input.operation {
        case .closeProject:
            guard workspace.closeProject(input.projectID!, skipConfirmation: true) else { throw TerminalProjectToolError.unavailable }
        case .closeTab:
            guard workspace.closeLayoutTab(input.layoutTabID!, skipConfirmation: true) else { throw TerminalProjectToolError.unavailable }
        default: sessions.forEach { workspace.closeProjectTerminal($0) }
        }
        return ids
    }

    private struct Selection {
        let projectID: UUID?
        let terminalID: UUID?
        init(_ workspace: TerminalWorkspace) { projectID = workspace.projectLayout.selectedProjectID; terminalID = workspace.selectedID }
        func restore(_ workspace: TerminalWorkspace) {
            guard let projectID, workspace.projectLayout.projects.contains(where: { $0.id == projectID }) else {
                workspace.selectedID = workspace.projectLayout.focusedTerminalID
                return
            }
            workspace.projectLayout.selectedProjectID = projectID
            if let terminalID, let position = workspace.projectLayout.location(of: terminalID),
               workspace.projectLayout.projects[position.0].id == projectID {
                workspace.selectedID = terminalID
                do { try workspace.projectLayout.select(terminal: terminalID) }
                catch { NSLog("QTerm could not restore project tool selection") }
            } else { workspace.selectedID = workspace.projectLayout.focusedTerminalID }
        }
    }
}
