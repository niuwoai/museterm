import Foundation

enum TerminalSplitAxis: String, Codable { case horizontal, vertical }

indirect enum TerminalPaneLayout: Codable, Equatable {
    case terminal(UUID)
    case split(id: UUID, axis: TerminalSplitAxis, ratio: Double, first: TerminalPaneLayout, second: TerminalPaneLayout)

    var terminalIDs: [UUID] {
        switch self {
        case .terminal(let id): return [id]
        case .split(_, _, _, let first, let second): return first.terminalIDs + second.terminalIDs
        }
    }

    var isValid: Bool {
        switch self {
        case .terminal: return true
        case .split(_, _, let ratio, let first, let second):
            return ratio.isFinite && (0.1...0.9).contains(ratio) && first.isValid && second.isValid
        }
    }

    var splitIDs: [UUID] {
        switch self {
        case .terminal: return []
        case .split(let id, _, _, let first, let second): return [id] + first.splitIDs + second.splitIDs
        }
    }

    func splitting(_ terminal: UUID, adding new: UUID, axis: TerminalSplitAxis) -> Self {
        switch self {
        case .terminal(let id):
            return id == terminal ? .split(id: UUID(), axis: axis, ratio: 0.5, first: self, second: .terminal(new)) : self
        case .split(let id, let direction, let ratio, let first, let second):
            return .split(id: id, axis: direction, ratio: ratio,
                first: first.splitting(terminal, adding: new, axis: axis), second: second.splitting(terminal, adding: new, axis: axis))
        }
    }

    func removing(_ terminal: UUID) -> Self? {
        switch self {
        case .terminal(let id): return id == terminal ? nil : self
        case .split(let id, let axis, let ratio, let first, let second):
            let left = first.removing(terminal)
            let right = second.removing(terminal)
            guard let left else { return right }
            guard let right else { return left }
            return .split(id: id, axis: axis, ratio: ratio, first: left, second: right)
        }
    }

    func resizing(_ split: UUID, ratio newRatio: Double) -> Self {
        switch self {
        case .terminal: return self
        case .split(let id, let axis, let ratio, let first, let second):
            let adjusted = newRatio.isFinite ? min(0.9, max(0.1, newRatio)) : ratio
            return .split(id: id, axis: axis, ratio: id == split ? adjusted : ratio,
                first: first.resizing(split, ratio: newRatio), second: second.resizing(split, ratio: newRatio))
        }
    }

    func mappingTerminals(_ transform: (UUID) throws -> UUID) rethrows -> Self {
        switch self {
        case .terminal(let id): return .terminal(try transform(id))
        case .split(let id, let axis, let ratio, let first, let second):
            return .split(id: id, axis: axis, ratio: ratio,
                first: try first.mappingTerminals(transform), second: try second.mappingTerminals(transform))
        }
    }
}

struct TerminalProjectTab: Codable, Equatable, Identifiable {
    var id = UUID()
    var layout: TerminalPaneLayout
    var focusedTerminalID: UUID
}

struct TerminalProject: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var directory: String?
    var tabs: [TerminalProjectTab]
    var selectedTabID: UUID?
}

enum TerminalProjectLayoutError: Error { case invalidLayout, missingTarget, duplicateTerminal, invalidName }

/// All positions reference stable terminal identities. Neither move nor split recreates a process.
struct TerminalProjectLayout: Codable, Equatable {
    var schemaVersion = 1
    var projects: [TerminalProject] = []
    var selectedProjectID: UUID?

    var terminalIDs: [UUID] { projects.flatMap { $0.tabs.flatMap { $0.layout.terminalIDs } } }
    var selectedProject: TerminalProject? { projects.first { $0.id == selectedProjectID } }
    var selectedTab: TerminalProjectTab? { selectedProject?.tabs.first { $0.id == selectedProject?.selectedTabID } }
    var focusedTerminalID: UUID? { selectedTab?.focusedTerminalID }

    func validate() throws {
        let terminals = terminalIDs
        let tabs = projects.flatMap(\.tabs)
        let splits = tabs.flatMap { $0.layout.splitIDs }
        guard schemaVersion == 1, Set(terminals).count == terminals.count,
              Set(splits).count == splits.count,
              Set(projects.map(\.id)).count == projects.count, Set(tabs.map(\.id)).count == tabs.count,
              selectedProjectID == nil ? projects.isEmpty : projects.contains(where: { $0.id == selectedProjectID }),
              projects.allSatisfy({ project in
                  !project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  && project.name.count <= 120
                  && (project.tabs.isEmpty ? project.selectedTabID == nil : project.tabs.contains { $0.id == project.selectedTabID })
                  && project.tabs.allSatisfy { $0.layout.isValid && $0.layout.terminalIDs.count <= 64 && $0.layout.terminalIDs.contains($0.focusedTerminalID) }
              }) else { throw TerminalProjectLayoutError.invalidLayout }
    }

    @discardableResult
    mutating func addProject(name: String, directory: String? = nil, terminal: UUID? = nil) throws -> UUID {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 120 else { throw TerminalProjectLayoutError.invalidName }
        if let terminal, terminalIDs.contains(terminal) { throw TerminalProjectLayoutError.duplicateTerminal }
        let tabs = terminal.map { [TerminalProjectTab(layout: .terminal($0), focusedTerminalID: $0)] } ?? []
        let project = TerminalProject(name: clean, directory: directory, tabs: tabs, selectedTabID: tabs.first?.id)
        projects.append(project)
        selectedProjectID = project.id
        return project.id
    }

    mutating func addTab(terminal: UUID, projectID: UUID) throws {
        guard !terminalIDs.contains(terminal) else { throw TerminalProjectLayoutError.duplicateTerminal }
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { throw TerminalProjectLayoutError.missingTarget }
        let tab = TerminalProjectTab(layout: .terminal(terminal), focusedTerminalID: terminal)
        projects[index].tabs.append(tab)
        projects[index].selectedTabID = tab.id
        selectedProjectID = projectID
    }

    mutating func select(terminal: UUID) throws {
        guard let (project, tab) = location(of: terminal) else { throw TerminalProjectLayoutError.missingTarget }
        projects[project].tabs[tab].focusedTerminalID = terminal
        projects[project].selectedTabID = projects[project].tabs[tab].id
        selectedProjectID = projects[project].id
    }

    mutating func split(terminal: UUID, adding new: UUID, axis: TerminalSplitAxis) throws {
        guard !terminalIDs.contains(new) else { throw TerminalProjectLayoutError.duplicateTerminal }
        guard let (project, tab) = location(of: terminal) else { throw TerminalProjectLayoutError.missingTarget }
        guard projects[project].tabs[tab].layout.terminalIDs.count < 64 else { throw TerminalProjectLayoutError.invalidLayout }
        projects[project].tabs[tab].layout = projects[project].tabs[tab].layout.splitting(terminal, adding: new, axis: axis)
        try select(terminal: new)
    }

    mutating func remove(terminal: UUID) throws {
        guard let (project, tab) = location(of: terminal) else { throw TerminalProjectLayoutError.missingTarget }
        if let remaining = projects[project].tabs[tab].layout.removing(terminal) {
            projects[project].tabs[tab].layout = remaining
            if projects[project].tabs[tab].focusedTerminalID == terminal {
                projects[project].tabs[tab].focusedTerminalID = remaining.terminalIDs[0]
            }
        } else {
            let removed = projects[project].tabs.remove(at: tab)
            if projects[project].selectedTabID == removed.id {
                projects[project].selectedTabID = projects[project].tabs[min(tab, max(0, projects[project].tabs.count - 1))...].first?.id
            }
        }
    }

    mutating func move(terminal: UUID, to projectID: UUID) throws {
        guard projects.contains(where: { $0.id == projectID }), location(of: terminal) != nil else {
            throw TerminalProjectLayoutError.missingTarget
        }
        try remove(terminal: terminal)
        try addTab(terminal: terminal, projectID: projectID)
    }

    func location(of terminal: UUID) -> (Int, Int)? {
        for (project, value) in projects.enumerated() {
            if let tab = value.tabs.firstIndex(where: { $0.layout.terminalIDs.contains(terminal) }) { return (project, tab) }
        }
        return nil
    }

    mutating func rename(projectID: UUID, name: String) throws {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 120 else { throw TerminalProjectLayoutError.invalidName }
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { throw TerminalProjectLayoutError.missingTarget }
        projects[index].name = clean
    }

    mutating func resize(splitID: UUID, ratio: Double) throws {
        guard ratio.isFinite, projects.contains(where: { $0.tabs.contains { $0.layout.splitIDs.contains(splitID) } }) else {
            throw TerminalProjectLayoutError.missingTarget
        }
        for project in projects.indices {
            for tab in projects[project].tabs.indices {
                projects[project].tabs[tab].layout = projects[project].tabs[tab].layout.resizing(splitID, ratio: ratio)
            }
        }
    }

    @discardableResult
    mutating func removeProject(_ id: UUID) throws -> [UUID] {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { throw TerminalProjectLayoutError.missingTarget }
        let removed = projects.remove(at: index)
        if selectedProjectID == id { selectedProjectID = projects.first?.id }
        return removed.tabs.flatMap { $0.layout.terminalIDs }
    }
}

struct TerminalProjectActivity: Codable, Equatable {
    let needsAnswer: Int
    let working: Int
    let unknown: Int
    let pending: Int
    let unread: Int

    init(project: TerminalProject, agents: [UUID: TerminalAgentSnapshot], attention: [TerminalAttentionItem]) {
        let ids = Set(project.tabs.flatMap { $0.layout.terminalIDs })
        let active = attention.filter { ids.contains($0.tabID) && $0.resolvedAt == nil }
        needsAnswer = active.filter { $0.kind.requiresAnswer }.count
        pending = active.count
        unread = active.filter { $0.readAt == nil }.count
        working = ids.filter { agents[$0]?.activity == .working }.count
        unknown = ids.filter { agents[$0]?.activity == .unknown }.count
    }
}
