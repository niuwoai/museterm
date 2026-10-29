import Foundation

/// One durable record per UI workspace. Process ownership stays in the service.
@MainActor
final class TerminalRuntimeWorkspaceLifecycle {
    static let shared = TerminalRuntimeWorkspaceLifecycle()
    private struct Entry { weak var workspace: TerminalWorkspace? }
    private var entries: [UUID: Entry] = [:]
    private var claimed: Set<UUID> = []
    private var pending: [UUID: DispatchWorkItem] = [:]
    private var renderedPending: [UUID: DispatchWorkItem] = [:]
    private static let persistenceDelay: TimeInterval = 0.3
    private let store: TerminalRuntimeWorkspaceStore
    private let enabled: Bool
    private let root: URL
    private var preparingForExit = false

    init(root: URL = TerminalRuntimeService.rootDirectory, enabled: Bool = TerminalRuntimeService.isEnabled) {
        store = TerminalRuntimeWorkspaceStore(root: root)
        self.enabled = enabled
        self.root = root
    }

    func makeWorkspace(automaticallyStartProcesses: Bool = true) -> TerminalWorkspace {
        guard enabled else { return TerminalWorkspace(automaticallyStartProcesses: automaticallyStartProcesses) }
        var recovered: TerminalRuntimeWorkspaceRecord?
        var failed = false
        do {
            for id in try store.recordIDs() where !claimed.contains(id) {
                claimed.insert(id)
                do { recovered = try store.load(id); break }
                catch { failed = true; NSLog("MuseTerm retained an unreadable workspace recovery record") }
            }
        } catch { failed = true; NSLog("MuseTerm could not read workspace recovery directory") }
        let workspace = TerminalWorkspace(automaticallyStartProcesses: automaticallyStartProcesses,
            restoringRuntimeRecord: recovered, deferInitialTab: recovered == nil)
        workspace.runtimeRecoveryIssue = failed
        for session in workspace.sessionRegistry.sessions.values { session.runtimeRecoveryRoot = root }
        attach(workspace)
        discoverOrphans(in: workspace)
        return workspace
    }

    private func discoverOrphans(in workspace: TerminalWorkspace) {
        workspace.runtimeDiscoveryInProgress = true
        let root = root
        Task { [weak self, weak workspace] in
            let result = await Task.detached { () -> Result<[TerminalRuntimeSessionInfo], Error> in
                // Discovery must never start/replace a service. A fresh install
                // without a socket simply proceeds with its normal new tab.
                guard FileManager.default.fileExists(atPath: root.appendingPathComponent("runtime.sock").path) else {
                    return .success([])
                }
                return Result {
                    let connection = try TerminalRuntimeConnection(root: root)
                    defer { connection.close() }
                    return try connection.request(.init(action: .list)).sessions ?? []
                }
            }.value
            guard let self, let workspace else { return }
            workspace.runtimeDiscoveryInProgress = false
            guard !preparingForExit, entries[workspace.runtimeWorkspaceID]?.workspace === workspace else { return }
            do {
                var reserved = Set(entries.values.compactMap(\.workspace).flatMap { $0.sessionRegistry.sessions.keys })
                // Reserve terminals in other, as-yet unopened windows too.
                for id in try store.recordIDs() {
                    do { reserved.formUnion(try store.load(id).snapshot.tabs.compactMap(\.terminalID)) }
                    catch { workspace.runtimeRecoveryIssue = true; NSLog("MuseTerm retained an unreadable recovery record during discovery") }
                }
                switch result {
                case .success(let sessions):
                    try workspace.adoptRuntimeOrphans(sessions.filter { !reserved.contains($0.id) }, root: root)
                case .failure(let error):
                    if case TerminalRuntimeConnectionError.unavailable = error {} else {
                        workspace.runtimeRecoveryIssue = true
                        NSLog("MuseTerm could not discover retained terminal sessions")
                    }
                }
            } catch {
                workspace.runtimeRecoveryIssue = true
                NSLog("MuseTerm could not recover retained terminals")
            }
            if workspace.sessionRegistry.sessions.isEmpty { workspace.newTab() }
            schedule(workspace)
        }
    }

    func attach(_ workspace: TerminalWorkspace) {
        let id = workspace.runtimeWorkspaceID
        entries[id] = Entry(workspace: workspace)
        claimed.insert(id)
        workspace.onRuntimePersistenceNeeded = { [weak self, weak workspace] in
            guard let self, let workspace else { return }
            self.schedule(workspace)
        }
        workspace.onRuntimeOutputRendered = { [weak self, weak workspace] in
            guard let self, let workspace else { return }
            self.scheduleRenderedCheckpoint(workspace)
        }
        workspace.onRuntimeRecordRemovalNeeded = { [weak self, weak workspace] in
            guard let self, let workspace else { return }
            do { try self.persist(workspace) }
            catch { workspace.runtimeRecoveryIssue = true; NSLog("MuseTerm could not remove a closed workspace recovery record") }
        }
        schedule(workspace)
    }

    func prepareForExit() throws {
        let workspaces = entries.values.compactMap(\.workspace)
        // Save every record before detaching any viewer. Failure keeps the UI
        // available for retry and never closes a service-owned terminal.
        for workspace in workspaces { try persist(workspace) }
        preparingForExit = true
        for workspace in workspaces { workspace.detachRuntimeForApplicationExit() }
    }

    private func schedule(_ workspace: TerminalWorkspace) {
        guard !preparingForExit else { return }
        let id = workspace.runtimeWorkspaceID
        pending[id]?.cancel()
        let work = DispatchWorkItem { [weak self, weak workspace] in
            guard let self, let workspace else { return }
            do { try self.persist(workspace) }
            catch { workspace.runtimeRecoveryIssue = true; NSLog("MuseTerm could not save workspace recovery record") }
        }
        pending[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.persistenceDelay, execute: work)
    }

    private func scheduleRenderedCheckpoint(_ workspace: TerminalWorkspace) {
        let id = workspace.runtimeWorkspaceID
        // Leading/trailing coalescing: continuous rendering must not keep
        // postponing the save as an ordinary debounce would.
        guard !preparingForExit, renderedPending[id] == nil else { return }
        let work = DispatchWorkItem { [weak self, weak workspace] in
            guard let self, let workspace else { return }
            do { try self.persist(workspace) }
            catch { workspace.runtimeRecoveryIssue = true; NSLog("MuseTerm could not save rendered output checkpoint") }
        }
        renderedPending[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.persistenceDelay, execute: work)
    }

    private func persist(_ workspace: TerminalWorkspace) throws {
        pending[workspace.runtimeWorkspaceID]?.cancel()
        pending[workspace.runtimeWorkspaceID] = nil
        renderedPending[workspace.runtimeWorkspaceID]?.cancel()
        renderedPending[workspace.runtimeWorkspaceID] = nil
        if workspace.sessionRegistry.sessions.isEmpty { try store.remove(workspace.runtimeWorkspaceID) }
        else { try store.save(workspace.runtimeWorkspaceRecord()) }
    }
}
