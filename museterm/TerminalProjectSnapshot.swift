import Foundation

extension TerminalWorkspaceSnapshot {
    /// Explicit recreation can remap terminals; a live runtime attach supplies their original IDs.
    func restoredProjectLayout(terminalIDs: [UUID], defaultName: String) throws -> TerminalProjectLayout {
        guard (1...2).contains(schemaVersion), tabs.count == terminalIDs.count,
              Set(terminalIDs).count == terminalIDs.count else { throw TerminalProjectLayoutError.invalidLayout }
        guard var layout = projectLayout else {
            var migrated = TerminalProjectLayout()
            let project = try migrated.addProject(name: defaultName)
            for terminal in terminalIDs { try migrated.addTab(terminal: terminal, projectID: project) }
            if let first = terminalIDs.indices.contains(selectedIndex) ? terminalIDs[selectedIndex] : terminalIDs.first {
                try migrated.select(terminal: first)
            }
            return migrated
        }
        try layout.validate()
        let old = tabs.compactMap(\.terminalID)
        guard old.count == tabs.count, Set(old).count == old.count, Set(old) == Set(layout.terminalIDs) else {
            throw TerminalProjectLayoutError.invalidLayout
        }
        let mapping = Dictionary(uniqueKeysWithValues: zip(old, terminalIDs))
        for project in layout.projects.indices {
            for tab in layout.projects[project].tabs.indices {
                layout.projects[project].tabs[tab].layout = try layout.projects[project].tabs[tab].layout.mappingTerminals { id in
                    guard let updated = mapping[id] else { throw TerminalProjectLayoutError.invalidLayout }
                    return updated
                }
                guard let focus = mapping[layout.projects[project].tabs[tab].focusedTerminalID] else {
                    throw TerminalProjectLayoutError.invalidLayout
                }
                layout.projects[project].tabs[tab].focusedTerminalID = focus
            }
        }
        try layout.validate()
        return layout
    }
}
