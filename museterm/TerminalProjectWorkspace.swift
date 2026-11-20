import AppKit
import Foundation

extension TerminalWorkspace {
    /// Imported projects are bookmarks. No shell is spawned and focus stays on the current terminal.
    @discardableResult
    func importProjects(_ candidates: [TerminalProjectImportCandidate]) throws -> Int {
        var layout = projectLayout
        let selected = layout.selectedProjectID
        var known = Set(layout.projects.compactMap { $0.directory.flatMap(TerminalProjectImportScanner.canonicalDirectory) })
        var added = 0
        for candidate in candidates {
            guard let directory = TerminalProjectImportScanner.canonicalDirectory(candidate.directory),
                  known.insert(directory).inserted else { continue }
            _ = try layout.addProject(name: candidate.name, directory: directory)
            added += 1
        }
        if let selected { layout.selectedProjectID = selected }
        try layout.validate()
        projectLayout = layout
        return added
    }

    func reconcileProjectLayout() {
        var layout = projectLayout
        let live = Set(tabs.map(\.id) + sessionRegistry.locations.filter { $0.value == .detached }.map(\.key))
        for terminal in layout.terminalIDs where !live.contains(terminal) {
            do { try layout.remove(terminal: terminal) }
            catch { NSLog("MuseTerm could not reconcile removed layout terminal") }
        }
        for tab in tabs where !layout.terminalIDs.contains(tab.id) {
            do {
                if layout.projects.isEmpty {
                    _ = try layout.addProject(name: L10n.string("project.default"), terminal: tab.id)
                } else {
                    try layout.addTab(terminal: tab.id, projectID: layout.selectedProjectID ?? layout.projects[0].id)
                }
            } catch { NSLog("MuseTerm could not reconcile new layout terminal") }
            tab.onPaneFocus = { [weak self, weak tab] in
                guard let self, let tab, self.selectedID != tab.id, self.tabs.contains(where: { $0.id == tab.id }) else { return }
                self.select(tab)
            }
        }
        if layout != projectLayout { projectLayout = layout }
    }

    func selectProjectTerminal(_ id: UUID) {
        guard projectLayout.location(of: id) != nil else { return }
        do { try projectLayout.select(terminal: id) }
        catch { NSLog("MuseTerm could not select project terminal") }
    }

    func selectProject(_ id: UUID) {
        guard projectLayout.projects.contains(where: { $0.id == id }) else { return }
        projectLayout.selectedProjectID = id
        selectedID = projectLayout.focusedTerminalID
        if let selectedID, sessionRegistry.locations[selectedID] == .detached {
            _ = DetachedTerminalPanelManager.shared.focus(selectedID)
        }
    }

    @discardableResult
    func createProject(name: String, directory: String? = nil) throws -> UUID {
        let id = try projectLayout.addProject(name: name, directory: directory)
        selectedID = nil
        newTab(startDirectory: directory)
        return id
    }

    func renameProject(_ id: UUID, name: String) throws { try projectLayout.rename(projectID: id, name: name) }

    func moveTerminal(_ terminal: UUID, to project: UUID) throws {
        try projectLayout.move(terminal: terminal, to: project)
        selectedID = terminal
    }

    @discardableResult
    func splitTerminal(_ terminal: UUID, axis: TerminalSplitAxis) throws -> TerminalSession {
        guard let source = tabs.first(where: { $0.id == terminal }), let location = projectLayout.location(of: terminal),
              !source.runtimeAttachOnly,
              projectLayout.projects[location.0].tabs[location.1].layout.terminalIDs.count < 64 else {
            throw TerminalProjectLayoutError.missingTarget
        }
        // newTab adopts a fresh session; its temporary standalone layout is removed before splitting.
        select(source)
        let created: TerminalSession
        switch source.launchConfiguration {
        case .localShell(_, let profile): created = newTab(startDirectory: source.currentDirectory, profile: profile)
        case .ssh(let profile): created = openSSH(profile: profile)
        }
        try projectLayout.remove(terminal: created.id)
        try projectLayout.split(terminal: terminal, adding: created.id, axis: axis)
        selectedID = created.id
        return created
    }

    func resizeSplit(_ id: UUID, ratio: Double) {
        do { try projectLayout.resize(splitID: id, ratio: ratio) }
        catch { NSLog("MuseTerm could not resize terminal split") }
    }

    @discardableResult
    func closeLayoutTab(_ id: UUID, skipConfirmation: Bool = false) -> Bool {
        guard let tab = projectLayout.projects.flatMap(\.tabs).first(where: { $0.id == id }) else { return false }
        let targets = sessionRegistry.sessions.values.filter { tab.layout.terminalIDs.contains($0.id) }
        if !skipConfirmation && targets.contains(where: \.hasForegroundProcess) {
            let alert = NSAlert()
            alert.messageText = L10n.string("project.close_tab.title")
            alert.informativeText = L10n.format("project.close_tab.message", targets.count)
            alert.addButton(withTitle: L10n.string("project.close.action"))
            alert.addButton(withTitle: L10n.string("action.cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
        }
        for target in targets { closeProjectTerminal(target) }
        return true
    }

    @discardableResult
    func closeProject(_ id: UUID, skipConfirmation: Bool = false) -> Bool {
        guard let project = projectLayout.projects.first(where: { $0.id == id }) else { return false }
        let targets = sessionRegistry.sessions.values.filter { project.tabs.flatMap { $0.layout.terminalIDs }.contains($0.id) }
        if !skipConfirmation && targets.contains(where: \.hasForegroundProcess) {
            let alert = NSAlert()
            alert.messageText = L10n.string("project.delete.title")
            alert.informativeText = L10n.format("project.delete.message", project.name, targets.count)
            alert.addButton(withTitle: L10n.string("project.delete.confirm_action"))
            alert.addButton(withTitle: L10n.string("action.cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
        }
        for target in targets { closeProjectTerminal(target) }
        do { _ = try projectLayout.removeProject(id) }
        catch { NSLog("MuseTerm could not remove closed project"); return false }
        selectedID = projectLayout.focusedTerminalID
        return true
    }

    func closeProjectTerminal(_ session: TerminalSession) {
        if sessionRegistry.locations[session.id] == .detached {
            if DetachedTerminalPanelManager.shared.isDetached(session.id) { DetachedTerminalPanelManager.shared.closeAndTerminate(session) }
            else { session.terminate() }
        } else { _ = close(session, skipConfirmation: true) }
    }
}
