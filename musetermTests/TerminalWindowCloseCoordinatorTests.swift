import XCTest
@testable import museterm

final class TerminalWindowCloseCoordinatorTests: XCTestCase {
    private final class RecordingTabCloseConfirmer: TerminalTabCloseConfirming {
        var shouldAllowClose = true
        private(set) var requestedTabTitles: [String] = []

        func shouldClose(tab: TerminalSession) -> Bool {
            requestedTabTitles.append(tab.tabTitle)
            return shouldAllowClose
        }
    }

    @MainActor
    func testWindowCloseRequestClosesSelectedTabButKeepsWindowOpen() throws {
        let confirmer = RecordingTabCloseConfirmer()
        let workspace = TerminalWorkspace(
            automaticallyStartProcesses: false,
            tabCloseConfirmer: confirmer
        )
        let firstTab = try XCTUnwrap(workspace.selectedTab)
        workspace.newTab()
        let secondTab = try XCTUnwrap(workspace.selectedTab)
        workspace.newTab()
        let thirdTab = try XCTUnwrap(workspace.selectedTab)
        workspace.select(secondTab)

        let coordinator = TerminalWindowCloseCoordinator()
        coordinator.bind(workspace: workspace)

        let shouldCloseWindow = coordinator.handleWindowCloseRequest()

        XCTAssertFalse(shouldCloseWindow)
        XCTAssertEqual(workspace.tabs.map(\.id), [firstTab.id, thirdTab.id])
        XCTAssertEqual(workspace.selectedID, thirdTab.id)
        XCTAssertEqual(confirmer.requestedTabTitles.count, 1)
    }

    @MainActor
    func testWindowCloseRequestDeduplicatesSameKeyboardEvent() throws {
        let confirmer = RecordingTabCloseConfirmer()
        let workspace = TerminalWorkspace(
            automaticallyStartProcesses: false,
            tabCloseConfirmer: confirmer
        )
        let firstTab = try XCTUnwrap(workspace.selectedTab)
        workspace.newTab()
        let secondTab = try XCTUnwrap(workspace.selectedTab)
        workspace.newTab()
        let thirdTab = try XCTUnwrap(workspace.selectedTab)
        workspace.select(secondTab)

        let coordinator = TerminalWindowCloseCoordinator()
        coordinator.bind(workspace: workspace)

        let firstShouldCloseWindow = coordinator.handleWindowCloseRequest(eventTimestamp: 300)
        let secondShouldCloseWindow = coordinator.handleWindowCloseRequest(eventTimestamp: 300)

        XCTAssertFalse(firstShouldCloseWindow)
        XCTAssertFalse(secondShouldCloseWindow)
        XCTAssertEqual(workspace.tabs.map(\.id), [firstTab.id, thirdTab.id])
        XCTAssertEqual(workspace.selectedID, thirdTab.id)
        XCTAssertEqual(confirmer.requestedTabTitles.count, 1)
    }

    @MainActor
    func testWindowCloseRequestKeepsWindowOpenWhenTabCloseIsCancelled() throws {
        let confirmer = RecordingTabCloseConfirmer()
        confirmer.shouldAllowClose = false
        let workspace = TerminalWorkspace(
            automaticallyStartProcesses: false,
            tabCloseConfirmer: confirmer
        )
        workspace.newTab()
        let selectedTab = try XCTUnwrap(workspace.selectedTab)

        let coordinator = TerminalWindowCloseCoordinator()
        coordinator.bind(workspace: workspace)

        let shouldCloseWindow = coordinator.handleWindowCloseRequest()

        XCTAssertFalse(shouldCloseWindow)
        XCTAssertEqual(workspace.tabs.count, 2)
        XCTAssertEqual(workspace.selectedID, selectedTab.id)
        XCTAssertEqual(confirmer.requestedTabTitles.count, 1)
    }

    @MainActor
    func testWindowCloseRequestAllowsRealAppTermination() {
        let workspace = TerminalWorkspace(automaticallyStartProcesses: false)
        workspace.newTab()
        let coordinator = TerminalWindowCloseCoordinator()
        coordinator.bind(workspace: workspace)

        TerminalWindowCloseState.isAppTerminating = true
        defer { TerminalWindowCloseState.isAppTerminating = false }
        let shouldCloseWindow = coordinator.handleWindowCloseRequest()

        XCTAssertTrue(shouldCloseWindow)
        XCTAssertEqual(workspace.tabs.count, 2)
    }
}
