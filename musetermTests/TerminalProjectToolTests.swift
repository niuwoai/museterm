import XCTest
@testable import museterm

@MainActor
final class TerminalProjectToolTests: XCTestCase {
    private func perform(_ input: TerminalProjectToolRequest, _ workspace: TerminalWorkspace,
                         transportBounds: Bool = true,
                         authorized: () -> Bool = { true }) throws -> TerminalToolResponse {
        var input = input
        if transportBounds {
            input.uiEpoch = input.uiEpoch ?? workspace.sessionRegistry.events.appEpoch
            input.deadlineMonotonic = input.deadlineMonotonic ?? TerminalProjectToolService.requestMonotonicTime() + 5
        }
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(input))
        let request = try JSONDecoder().decode(TerminalToolRequest.self,
            from: JSONSerialization.data(withJSONObject: ["id": UUID().uuidString,
                "action": TerminalProjectToolService.action, "projectRequest": body]))
        return TerminalProjectToolService.perform(request, workspace: workspace, snapshotSequence: 1, authorized: authorized)
    }

    func testReadDoesNotRequestPairingAndWritesFailClosed() throws {
        let workspace = TerminalWorkspace(automaticallyStartProcesses: false, profileStore: nil)
        let before = workspace.projectLayout
        XCTAssertEqual(try perform(.init(operation: .createProject, name: "unbounded"), workspace, transportBounds: false).error,
            "invalid_project_request")
        let read = try perform(.init(operation: .list), workspace) { XCTFail("Read must not ask for credentials"); return false }
        XCTAssertTrue(read.ok)
        XCTAssertEqual(read.projectResult?.layout, before)
        let denied = try perform(.init(operation: .createProject, name: "blocked"), workspace) { false }
        XCTAssertEqual(denied.error, "project_access_denied")
        XCTAssertEqual(workspace.projectLayout, before)
    }

    func testReadAggregatesSameAgentAndPendingStorePerProject() throws {
        let workspace = TerminalWorkspace(automaticallyStartProcesses: false, profileStore: nil)
        let session = try XCTUnwrap(workspace.selectedTab), project = try XCTUnwrap(workspace.projectLayout.selectedProjectID)
        let grant = try session.bindAgent(kind: .willdeep)
        try session.reportAgent(.init(instanceID: grant.instanceID, runID: grant.runID, token: grant.token,
            sequence: 1, activity: .blocked, blockReason: .approval))
        let response = try perform(.init(operation: .list), workspace)
        let activity = try XCTUnwrap(response.projectResult?.activities[project.uuidString])
        XCTAssertEqual(activity.needsAnswer, 1)
        XCTAssertEqual(activity.pending, 1)
        XCTAssertEqual(activity.unread, 1)
        XCTAssertEqual(activity.working, 0)
    }

    func testNewTabInEmptiedProjectUsesItsSavedDirectory() throws {
        let workspace = TerminalWorkspace(automaticallyStartProcesses: false, profileStore: nil)
        let originalProject = try XCTUnwrap(workspace.projectLayout.selectedProjectID)
        let created = try XCTUnwrap(perform(.init(operation: .createProject, name: "cwd", directory: "/private/tmp"), workspace).projectResult)
        let terminal = try XCTUnwrap(created.terminalID), project = try XCTUnwrap(created.projectID)
        XCTAssertTrue(try perform(.init(operation: .moveTerminal, projectID: originalProject, terminalID: terminal), workspace).ok)
        let result = try perform(.init(operation: .createTab, projectID: project), workspace)
        let newID = try XCTUnwrap(result.projectResult?.terminalID)
        XCTAssertEqual(workspace.sessionRegistry.sessions[newID]?.launchConfiguration.localStartDirectory, "/private/tmp")
    }

    func testSameNameAndDirectoryProjectsKeepDistinctIdentityAndAttention() throws {
        let workspace = TerminalWorkspace(automaticallyStartProcesses: false, profileStore: nil)
        let first = try perform(.init(operation: .createProject, name: "same", directory: "/private/tmp"), workspace)
        let second = try perform(.init(operation: .createProject, name: "same", directory: "/private/tmp"), workspace)
        let firstProject = try XCTUnwrap(first.projectResult?.projectID)
        let secondProject = try XCTUnwrap(second.projectResult?.projectID)
        let firstTerminal = try XCTUnwrap(first.projectResult?.terminalID)
        let secondTerminal = try XCTUnwrap(second.projectResult?.terminalID)
        XCTAssertNotEqual(firstProject, secondProject)
        XCTAssertNotEqual(firstTerminal, secondTerminal)
        let question = try XCTUnwrap(workspace.sessionRegistry.attention.recordTerminal(.init(kind: .bell,
            eventID: UUID(), commandID: nil, exitCode: nil, failed: false), tabID: firstTerminal))
        let listed = try perform(.init(operation: .list), workspace)
        XCTAssertEqual(listed.projectResult?.activities[firstProject.uuidString]?.pending, 1)
        XCTAssertEqual(listed.projectResult?.activities[secondProject.uuidString]?.pending, 0)
        _ = try perform(.init(operation: .focus, terminalID: secondTerminal), workspace)
        XCTAssertEqual(workspace.selectedID, secondTerminal)
        XCTAssertTrue(workspace.sessionRegistry.attention.hasUnread(tabID: firstTerminal))
        XCTAssertEqual(workspace.sessionRegistry.attention.activeItems.first?.id, question.id)
        try workspace.projectLayout.validate()
    }

    func testBackgroundCreationSplitAndMoveKeepFocusAndUnread() throws {
        let workspace = TerminalWorkspace(automaticallyStartProcesses: false, profileStore: nil)
        let original = try XCTUnwrap(workspace.selectedTab), firstProject = try XCTUnwrap(workspace.projectLayout.selectedProjectID)
        let item = try XCTUnwrap(workspace.sessionRegistry.attention.recordTerminal(.init(kind: .bell,
            eventID: UUID(), commandID: nil, exitCode: nil, failed: false), tabID: original.id))
        let created = try perform(.init(operation: .createProject, name: "review", directory: "/private/tmp"), workspace)
        let project = try XCTUnwrap(created.projectResult?.projectID)
        XCTAssertTrue(created.ok)
        XCTAssertEqual(workspace.selectedID, original.id)
        let split = try perform(.init(operation: .split, terminalID: original.id, axis: .vertical), workspace)
        let newTerminal = try XCTUnwrap(split.projectResult?.terminalID)
        let layoutTab = try XCTUnwrap(split.projectResult?.layoutTabID)
        let splitIDs = try XCTUnwrap(workspace.projectLayout.projects.first(where: { $0.id == firstProject })?.tabs.first?.layout.splitIDs)
        XCTAssertEqual(workspace.selectedID, original.id)
        XCTAssertEqual(workspace.sessionRegistry.attention.activeItems.first?.id, item.id)
        XCTAssertTrue(workspace.sessionRegistry.attention.hasUnread(tabID: original.id))
        let moved = try perform(.init(operation: .moveTab, projectID: project, layoutTabID: layoutTab), workspace)
        XCTAssertTrue(moved.ok)
        let target = try XCTUnwrap(workspace.projectLayout.projects.first(where: { $0.id == project })?.tabs.first(where: { $0.id == layoutTab }))
        XCTAssertEqual(target.layout.terminalIDs, [original.id, newTerminal])
        XCTAssertEqual(target.layout.splitIDs, splitIDs)
        XCTAssertEqual(workspace.projectLayout.selectedProjectID, firstProject)
        XCTAssertTrue(workspace.sessionRegistry.attention.hasUnread(tabID: original.id))
        try workspace.projectLayout.validate()
    }

    func testStaleScopeAndInvalidDirectoryDoNotChangeLayout() throws {
        let workspace = TerminalWorkspace(automaticallyStartProcesses: false, profileStore: nil)
        let before = workspace.projectLayout
        let stale = try perform(.init(operation: .createProject, name: "stale", expectedEpoch: UUID(), expectedRevision: 0), workspace)
        XCTAssertEqual(stale.error, "project_layout_changed")
        let invalid = try perform(.init(operation: .createProject, name: "invalid", directory: "/museterm-does-not-exist-\(UUID())"), workspace)
        XCTAssertEqual(invalid.error, "invalid_project_request")
        let foreign = try perform(.init(operation: .list, workspaceID: UUID()), workspace)
        XCTAssertEqual(foreign.error, "project_target_unavailable")
        XCTAssertEqual(try perform(.init(operation: .createProject, name: "late", deadlineMonotonic: -1), workspace).error,
            "project_request_expired")
        XCTAssertEqual(try perform(.init(operation: .createProject, name: "old UI", uiEpoch: UUID()), workspace).error,
            "project_layout_changed")
        XCTAssertEqual(try perform(.init(operation: .createProject, name: "wrong clock", deadlineMonotonic: TerminalProjectToolService.requestMonotonicTime() + 600), workspace).error,
            "invalid_project_request")
        XCTAssertEqual(workspace.projectLayout, before)
    }

    func testReorderResizeRenameAndExplicitFocusUseStableIDs() throws {
        let workspace = TerminalWorkspace(automaticallyStartProcesses: false, profileStore: nil)
        let terminal = try XCTUnwrap(workspace.selectedID), first = try XCTUnwrap(workspace.projectLayout.selectedProjectID)
        let project = try XCTUnwrap(perform(.init(operation: .createProject, name: "second"), workspace).projectResult?.projectID)
        XCTAssertTrue(try perform(.init(operation: .renameProject, projectID: project, name: "renamed"), workspace).ok)
        XCTAssertTrue(try perform(.init(operation: .reorderProjects, order: [project, first]), workspace).ok)
        XCTAssertEqual(workspace.projectLayout.projects.map(\.id), [project, first])
        _ = try perform(.init(operation: .split, terminalID: terminal, axis: .horizontal), workspace)
        let split = try XCTUnwrap(workspace.projectLayout.projects.first(where: { $0.id == first })?.tabs.first?.layout.splitIDs.first)
        XCTAssertTrue(try perform(.init(operation: .resizeSplit, splitID: split, ratio: 0.7), workspace).ok)
        let before = workspace.projectLayout
        XCTAssertFalse(try perform(.init(operation: .resizeSplit, splitID: split, ratio: 1), workspace).ok)
        XCTAssertEqual(workspace.projectLayout, before)
        XCTAssertTrue(try perform(.init(operation: .focus, projectID: project), workspace).ok)
        XCTAssertEqual(workspace.projectLayout.selectedProjectID, project)
        try workspace.projectLayout.validate()
    }

    func testNonRunningCloseReturnsRequestedClosure() throws {
        let workspace = TerminalWorkspace(automaticallyStartProcesses: false, profileStore: nil)
        let session = try XCTUnwrap(workspace.selectedTab)
        XCTAssertFalse(session.hasRunningProcess)
        let closed = try perform(.init(operation: .closeTerminal, terminalID: session.id), workspace)
        XCTAssertTrue(closed.ok)
        XCTAssertEqual(closed.projectResult?.removedTerminalIDs, [session.id])
        XCTAssertEqual(closed.projectResult?.processClosure, "requested")
        XCTAssertFalse(workspace.projectLayout.terminalIDs.contains(session.id))
    }

    func testRevisionDetectsConcurrentMutationsAndDuplicateOrderIsRejected() throws {
        let workspace = TerminalWorkspace(automaticallyStartProcesses: false, profileStore: nil)
        let baseline = try XCTUnwrap(perform(.init(operation: .list), workspace).projectResult)
        let first = try XCTUnwrap(workspace.projectLayout.selectedProjectID)
        XCTAssertTrue(try perform(.init(operation: .renameProject, projectID: first, name: "renamed",
            expectedEpoch: baseline.appEpoch, expectedRevision: baseline.revision), workspace).ok)
        let before = workspace.projectLayout
        XCTAssertEqual(try perform(.init(operation: .renameProject, projectID: first, name: "stale",
            expectedEpoch: baseline.appEpoch, expectedRevision: baseline.revision), workspace).error, "project_layout_changed")
        XCTAssertFalse(try perform(.init(operation: .reorderProjects, order: [first, first]), workspace).ok)
        XCTAssertEqual(workspace.projectLayout, before)
    }

    func testReorderingLayoutTabsKeepsTreesAndFocus() throws {
        let workspace = TerminalWorkspace(automaticallyStartProcesses: false, profileStore: nil)
        let original = try XCTUnwrap(workspace.selectedID), project = try XCTUnwrap(workspace.projectLayout.selectedProjectID)
        _ = try perform(.init(operation: .split, terminalID: original, axis: .horizontal), workspace)
        _ = try perform(.init(operation: .createTab, projectID: project), workspace)
        let tabs = try XCTUnwrap(workspace.projectLayout.projects.first?.tabs)
        let order = tabs.map(\.id).reversed()
        XCTAssertTrue(try perform(.init(operation: .reorderTabs, projectID: project, order: Array(order)), workspace).ok)
        XCTAssertEqual(workspace.projectLayout.projects.first?.tabs.map(\.id), Array(order))
        for tab in tabs {
            XCTAssertEqual(workspace.projectLayout.projects.first?.tabs.first(where: { $0.id == tab.id }), tab)
        }
        XCTAssertEqual(workspace.selectedID, original)
        let before = workspace.projectLayout
        XCTAssertFalse(try perform(.init(operation: .reorderTabs, projectID: project, order: [tabs[0].id, tabs[0].id]), workspace).ok)
        XCTAssertEqual(workspace.projectLayout, before)
    }

    func testCloseLayoutTabAndProjectKeepUnrelatedTerminalAndUnread() throws {
        let workspace = TerminalWorkspace(automaticallyStartProcesses: false, profileStore: nil)
        let original = try XCTUnwrap(workspace.selectedTab)
        _ = workspace.sessionRegistry.attention.recordTerminal(.init(kind: .bell, eventID: UUID(),
            commandID: nil, exitCode: nil, failed: false), tabID: original.id)
        let a = try XCTUnwrap(perform(.init(operation: .createProject, name: "a"), workspace).projectResult)
        let aRoot = try XCTUnwrap(a.terminalID), aTab = try XCTUnwrap(a.layoutTabID)
        let split = try XCTUnwrap(perform(.init(operation: .split, terminalID: aRoot, axis: .vertical), workspace).projectResult?.terminalID)
        let b = try XCTUnwrap(perform(.init(operation: .createProject, name: "b"), workspace).projectResult)
        let bProject = try XCTUnwrap(b.projectID), bRoot = try XCTUnwrap(b.terminalID)
        let closedTab = try perform(.init(operation: .closeTab, layoutTabID: aTab), workspace)
        XCTAssertTrue(closedTab.ok)
        XCTAssertEqual(Set(try XCTUnwrap(closedTab.projectResult?.removedTerminalIDs)), Set([aRoot, split]))
        XCTAssertNotNil(workspace.sessionRegistry.sessions[bRoot])
        let closedProject = try perform(.init(operation: .closeProject, projectID: bProject), workspace)
        XCTAssertTrue(closedProject.ok)
        XCTAssertEqual(closedProject.projectResult?.removedTerminalIDs, [bRoot])
        XCTAssertEqual(workspace.selectedID, original.id)
        XCTAssertEqual(Set(workspace.sessionRegistry.sessions.keys), Set([original.id]))
        XCTAssertTrue(workspace.sessionRegistry.attention.hasUnread(tabID: original.id))
        try workspace.projectLayout.validate()
    }
}
