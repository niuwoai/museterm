import XCTest
@testable import museterm

@MainActor
final class TerminalNativeAgentTests: XCTestCase {
    private func request(tab: UUID, token: String?, kind: String = "willdeep") throws -> TerminalToolRequest {
        var value: [String: Any] = ["id": UUID().uuidString, "action": "bind_native_agent", "tab": tab.uuidString, "agentKind": kind]
        if let token { value["nativeAgentToken"] = token }
        return try JSONDecoder().decode(TerminalToolRequest.self, from: JSONSerialization.data(withJSONObject: value))
    }

    func testBootstrapIsPrivateAndOnlyBindsStatusForItsOwnTerminal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-status-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = TerminalSessionRegistry()
        let tab = TerminalSession(sequence: 1)
        let other = TerminalSession(sequence: 2)
        registry.register(tab); registry.register(other)
        let path = try tab.nativeAgentContext.prepare(tabID: tab.id, root: root)
        let context = try JSONDecoder().decode(TerminalNativeAgentContext.Descriptor.self, from: Data(contentsOf: path))
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.intValue & 0o777, 0o600)
        let parentMode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: path.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(parentMode.intValue & 0o777, 0o700)
        XCTAssertEqual(context.tabID, tab.id)
        let response = TerminalAgentToolService.perform(try request(tab: tab.id, token: context.token), registry: registry,
            snapshotSequence: 1, paired: { XCTFail("Native status must not borrow control pairing"); return false })
        XCTAssertTrue(response.ok)
        XCTAssertNotNil(response.agentGrant)
        XCTAssertNil(tab.aiLease)
        for rejected in [try request(tab: other.id, token: context.token), try request(tab: tab.id, token: nil),
                         try request(tab: tab.id, token: context.token, kind: "codex")] {
            XCTAssertFalse(TerminalAgentToolService.perform(rejected, registry: registry, snapshotSequence: 1, paired: { true }).ok)
        }
        tab.terminate()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        XCTAssertFalse(tab.nativeAgentContext.authorizes(context.token))
    }

    func testTrackingDisabledRejectsNativeBinding() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-disabled-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = TerminalSessionRegistry()
        let tab = TerminalSession(sequence: 1)
        registry.register(tab)
        _ = try tab.nativeAgentContext.prepare(tabID: tab.id, root: root)
        registry.setAgentMonitoringEnabled(false)
        let result = TerminalAgentToolService.perform(try request(tab: tab.id, token: tab.nativeAgentContext.token),
            registry: registry, snapshotSequence: 1, paired: { true })
        XCTAssertFalse(result.ok)
        XCTAssertNil(tab.agentStatus)
    }

    func testDistinctGatesAndTasksDoNotCollapseIntoOldAttention() throws {
        let registry = TerminalSessionRegistry()
        let tab = TerminalSession(sequence: 1)
        registry.register(tab)
        let grant = try tab.bindAgent(kind: .willdeep)
        let session = UUID()
        func report(_ sequence: UInt64, _ activity: TerminalAgentActivity, task: String, gate: String? = nil,
                    result: TerminalAgentResult? = nil) throws {
            try tab.reportAgent(TerminalAgentReport(instanceID: grant.instanceID, runID: grant.runID, token: grant.token,
                sequence: sequence, activity: activity, blockReason: activity == .blocked ? .approval : nil,
                result: result, context: TerminalAgentReportedContext(sessionID: session, taskID: task, gateID: gate)))
        }
        try report(1, .blocked, task: "task-1", gate: "gate-1")
        let old = try XCTUnwrap(registry.attention.activeItems.first)
        registry.attention.markViewed(tabID: tab.id)
        try report(2, .blocked, task: "task-1", gate: "gate-2")
        let next = try XCTUnwrap(registry.attention.activeItems.first)
        XCTAssertNotEqual(old.id, next.id)
        XCTAssertNil(next.readAt)
        XCTAssertTrue(tab.hasUnreadAttention)
        try report(3, .idle, task: "task-1", result: .completed)
        let done = try XCTUnwrap(registry.attention.activeItems.first)
        try report(4, .idle, task: "task-2", result: .completed)
        XCTAssertNotEqual(done.id, registry.attention.activeItems.first?.id)
        XCTAssertEqual(registry.attention.activeItems.count, 1)
    }

    func testNativeIdentityMetadataRejectsTextAndDoesNotGuessScreens() throws {
        let tab = TerminalSession(sequence: 1)
        let grant = try tab.bindAgent(kind: .willdeep)
        XCTAssertThrowsError(try tab.reportAgent(TerminalAgentReport(instanceID: grant.instanceID, runID: grant.runID,
            token: grant.token, sequence: 1, activity: .working,
            context: TerminalAgentReportedContext(sessionID: UUID(), taskID: "private command text with spaces"))))
        XCTAssertEqual(TerminalAgentScreenRules.detect(kind: .willdeep,
            screen: "Do you want to proceed?\n❯ 1. Yes\n2. No").activity, .unknown)
    }
}
