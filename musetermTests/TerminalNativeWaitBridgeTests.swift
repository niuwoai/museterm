import XCTest
@testable import museterm

@MainActor
final class TerminalNativeWaitBridgeTests: XCTestCase {
    func testDetachedSessionCanBeQueriedAndCancelledWhileNativeBridgeWaits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("museterm-native-wait-\(UUID())")
        let workspace = TerminalWorkspace(automaticallyStartProcesses: false, profileStore: nil)
        let session = try XCTUnwrap(workspace.selectedTab)
        let grant = try session.bindAgent(kind: .codex)
        try session.reportAgent(TerminalAgentReport(instanceID: grant.instanceID, runID: grant.runID,
            token: grant.token, sequence: 1, activity: .blocked, blockReason: .question))
        _ = workspace.detachTab(session)
        let bridge = TerminalToolBridge(rootDirectory: root)
        bridge.attach(workspace: workspace)
        defer { bridge.stop(); try? FileManager.default.removeItem(at: root) }
        let waitID = UUID().uuidString, owner = UUID().uuidString
        let spec = TerminalWaitSpec(condition: .agentState, after: workspace.sessionRegistry.events.cursor,
            tabID: session.id, instanceID: grant.instanceID, runID: grant.runID, activity: .working)
        let specJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(spec)) as? [String: Any])
        try send(["id": waitID, "action": "wait_session", "controlID": owner, "waitSpec": specJSON], root: root)
        let acceptedBy = Date().addingTimeInterval(5)
        while workspace.sessionRegistry.waits.pendingCount == 0, Date() < acceptedBy {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(workspace.sessionRegistry.waits.pendingCount, 1)
        let queryID = UUID().uuidString
        try send(["id": queryID, "action": "get_agent_state", "tab": session.id.uuidString], root: root)
        let query = try await receive(queryID, root: root)
        XCTAssertEqual((query["agent"] as? [String: Any])?["activity"] as? String, "blocked")
        XCTAssertEqual(workspace.sessionRegistry.waits.pendingCount, 1)
        let cancellation = UUID().uuidString
        try send(["id": cancellation, "action": "cancel_wait", "controlID": owner, "waitID": waitID], root: root)
        let result = try await receive(waitID, root: root)
        XCTAssertEqual((result["waitResult"] as? [String: Any])?["outcome"] as? String, "cancelled")
        XCTAssertEqual(workspace.sessionRegistry.waits.pendingCount, 0)
        XCTAssertNil(session.aiLease)
        XCTAssertEqual(workspace.sessionRegistry.locations[session.id], .detached)
    }

    private func send(_ request: [String: Any], root: URL) throws {
        let id = try XCTUnwrap(request["id"] as? String)
        try TerminalToolPrivateWriter.write(JSONSerialization.data(withJSONObject: request),
            to: root.appendingPathComponent("requests/\(id).json"))
    }

    private func receive(_ id: String, root: URL) async throws -> [String: Any] {
        let path = root.appendingPathComponent("responses/\(id).json")
        let deadline = Date().addingTimeInterval(5)
        repeat {
            if let data = try? Data(contentsOf: path), let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] { return value }
            try await Task.sleep(nanoseconds: 20_000_000)
        } while Date() < deadline
        throw NSError(domain: "Native bridge timeout", code: 1)
    }
}
