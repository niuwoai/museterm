import Combine
import Foundation
import XCTest
@testable import museterm

@MainActor
final class TerminalSidebarRowStateTests: XCTestCase {
    func testOutputFramesAndCommandSnapshotsDoNotPublishRowChanges() {
        let session = TerminalSession(sequence: 1)
        let history = "prompt\n"
        session.startShellIntegratedCommand(command: "build", historySnapshot: history)
        let generation = UUID()
        let controlEpoch = UUID()
        var rowUpdates = 0
        let observation = session.sidebarRow.objectWillChange.sink { rowUpdates += 1 }
        defer { observation.cancel() }

        for frame in 1...8 {
            session.runtimeRestoreHidden = false
            session.applyRuntimeInfo(.init(
                id: session.id, revision: 1, pid: 1, generation: generation, controlEpoch: controlEpoch,
                directory: "/tmp", running: true, exitStatus: nil, columns: 80, rows: 24,
                outputOffset: UInt64(frame), controlOwner: nil, nextInputSequence: 0, agent: nil
            ))
            session.runtimeConnectionIssue = nil
            session.observeProcessOutput(historySnapshot: history + "output \(frame)\n")
            session.recordOutputRevision(frame)
        }

        XCTAssertEqual(rowUpdates, 0)
        XCTAssertEqual(session.runtimeInfo?.outputOffset, 8)
        XCTAssertEqual(session.lastOutputRevision, 8)
        XCTAssertEqual(session.historySearchSnapshot, history + "output 8\n")
        XCTAssertEqual(session.commandBlocks.last?.outputTail, "output 8\n")
    }

    func testRowPublishesActualLabelAndIndicatorChanges() {
        let session = TerminalSession(sequence: 1, launchConfiguration: .localShell(startDirectory: "/tmp/initial"))
        let row = session.sidebarRow
        XCTAssertEqual(row.value.labels.title, "initial")
        var values: [TerminalSidebarRowState.Value] = []
        let observation = row.$value.dropFirst().sink { values.append($0) }
        defer { observation.cancel() }

        session.title = "plain window title"
        session.currentDirectory = "/var/initial"
        XCTAssertTrue(values.isEmpty)

        session.currentDirectory = "/tmp/changed"
        XCTAssertEqual(values.last?.labels.title, "changed")
        session.title = "test-user@remote.invalid:/tmp/changed"
        XCTAssertEqual(values.last?.labels.title, "test-user@remote.invalid")
        XCTAssertEqual(values.last?.labels.subtitle, "changed")
        session.updateShellName("/bin/zsh")
        XCTAssertEqual(values.last?.shellName, "zsh")
        session.updateUnreadAttention(true)
        session.updateUnreadAttention(true)
        session.updateUnreadAttention(false)
        XCTAssertEqual(values.suffix(2).map(\.hasUnreadAttention), [true, false])
        session.state = .exited(0)
        session.state = .exited(1)
        session.state = .running
        XCTAssertEqual(values.suffix(2).map(\.isRunning), [false, true])
        XCTAssertEqual(values.count, 7)
        XCTAssertTrue(session.sidebarRow === row)
    }

    func testLeaseRenewalAndTunnelCountersDoNotPublishRowChanges() {
        let session = TerminalSession(sequence: 1)
        let generation = UUID()
        let controlEpoch = UUID()
        let expiresAt = Date(timeIntervalSince1970: 100)
        var values: [TerminalSidebarRowState.Value] = []
        let observation = session.sidebarRow.$value.dropFirst().sink { values.append($0) }
        defer { observation.cancel() }

        func applyLease(expires: Date?) {
            session.applyRuntimeInfo(.init(
                id: session.id, revision: 1, pid: 1, generation: generation, controlEpoch: controlEpoch,
                directory: "/tmp", running: true, exitStatus: nil, columns: 80, rows: 24,
                outputOffset: 0, controlOwner: expires == nil ? nil : "fixture-owner",
                nextInputSequence: 0, agent: nil, controlExpiresAt: expires
            ))
        }
        applyLease(expires: expiresAt)
        applyLease(expires: expiresAt.addingTimeInterval(1))
        applyLease(expires: nil)
        XCTAssertEqual(values.map(\.isAIControlled), [true, false])

        var tunnel = SessionTunnelStatus.starting(configuration: .init(
            name: "fixture", targetHost: "localhost", targetPort: 8080, localPort: 8081
        ))
        session.updateSessionTunnelStatus(tunnel)
        tunnel.phase = .running
        tunnel.uploadedBytes = 256
        session.updateSessionTunnelStatus(tunnel)
        tunnel.phase = .failed
        session.updateSessionTunnelStatus(tunnel)
        XCTAssertEqual(values.suffix(2).map(\.hasActiveTunnel), [true, false])
        XCTAssertEqual(values.count, 4)
    }

    func testAgentBadgeUpdatesForVisibleChangesButNotHeartbeatMetadata() throws {
        let session = TerminalSession(sequence: 1)
        let now = Date(timeIntervalSince1970: 100)
        let grant = try session.bindAgent(kind: .codex, now: now)
        var values: [TerminalSidebarRowState.Value] = []
        let observation = session.sidebarRow.$value.dropFirst().sink { values.append($0) }
        defer { observation.cancel() }

        func report(_ sequence: UInt64, title: String, activity: TerminalAgentActivity) throws {
            try session.reportAgent(.init(
                instanceID: grant.instanceID, runID: grant.runID, token: grant.token,
                sequence: sequence, activity: activity,
                context: .init(sessionID: session.id, taskID: "task-\(sequence)", title: title)
            ), now: now.addingTimeInterval(Double(sequence)))
        }
        try report(1, title: "Build", activity: .working)
        try report(2, title: " Build ", activity: .working)
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(session.agentStatus?.reportSequence, 2)
        try report(3, title: "Test", activity: .working)
        try report(4, title: "Test", activity: .idle)
        XCTAssertEqual(values.count, 3)
        XCTAssertEqual(values.map { $0.agent?.status.context?.title }, ["Build", "Test", "Test"])
        XCTAssertEqual(values.last?.agent?.status.activity, .idle)
    }
}
