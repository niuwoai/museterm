import XCTest
@testable import museterm

@MainActor
final class TerminalAgentToolTests: XCTestCase {
    private func request(_ action: String, tab: UUID? = nil, extra: [String: Any] = [:]) throws -> TerminalToolRequest {
        var fields: [String: Any] = ["id": UUID().uuidString, "action": action]
        fields["tab"] = tab?.uuidString
        fields.merge(extra) { _, new in new }
        return try JSONDecoder().decode(TerminalToolRequest.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    func testBindingRequiresPairingAndDoesNotGrantInput() throws {
        let registry = TerminalSessionRegistry()
        let session = TerminalSession(sequence: 1)
        registry.register(session)
        let bind = try request("bind_agent", tab: session.id, extra: ["agentKind": "codex"])
        let denied = TerminalAgentToolService.perform(bind, registry: registry, snapshotSequence: 1, paired: { false })
        XCTAssertFalse(denied.ok)
        XCTAssertNil(session.agentStatus)
        let accepted = TerminalAgentToolService.perform(bind, registry: registry, snapshotSequence: 1, paired: { true })
        XCTAssertTrue(accepted.ok)
        XCTAssertNotNil(accepted.agentGrant)
        XCTAssertNil(session.aiLease)
        XCTAssertFalse(session.aiRequiresTakeover)
    }

    func testStatusCapabilityCannotReportToAnotherTerminal() throws {
        let registry = TerminalSessionRegistry()
        let first = TerminalSession(sequence: 1)
        let second = TerminalSession(sequence: 2)
        registry.register(first)
        registry.register(second)
        let grant = try first.bindAgent(kind: .codex)
        let report: [String: Any] = ["instanceID": grant.instanceID.uuidString, "runID": grant.runID.uuidString,
            "token": grant.token, "sequence": 1, "activity": "working"]
        let response = TerminalAgentToolService.perform(
            try request("report_agent_state", tab: second.id, extra: ["agentReport": report]),
            registry: registry, snapshotSequence: 2, paired: { XCTFail("reports must not access pairing"); return false })
        XCTAssertFalse(response.ok)
        XCTAssertNil(second.agentStatus)
        let text = String(decoding: try JSONEncoder().encode(response), as: UTF8.self)
        XCTAssertFalse(text.contains(grant.token))
    }

    func testStatusReadingIncludesDetachedSessionWithoutPairing() throws {
        let registry = TerminalSessionRegistry()
        let session = TerminalSession(sequence: 1)
        registry.register(session, location: .detached)
        _ = try session.bindAgent(kind: .claude)
        let response = TerminalAgentToolService.perform(try request("get_agent_state", tab: session.id),
            registry: registry, snapshotSequence: 2, paired: { XCTFail("read must not access pairing"); return false })
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.agent?.kind, .claude)
        XCTAssertNil(response.agentGrant)
        let encoded = String(decoding: try JSONEncoder().encode(registry.snapshots), as: UTF8.self)
        XCTAssertFalse(encoded.contains("token"))
    }

    func testEventReadReturnsMachineReadableExpiryAndRestart() throws {
        let registry = TerminalSessionRegistry(events: TerminalSessionEventStore(capacity: 1))
        registry.events.publish(tabID: UUID(), kind: .registered)
        registry.events.publish(tabID: UUID(), kind: .closed)
        let expired = try request("read_session_events", extra: ["eventCursor": ["appEpoch": registry.events.appEpoch.uuidString, "sequence": 0]])
        XCTAssertEqual(TerminalAgentToolService.perform(expired, registry: registry,
            snapshotSequence: 1, paired: { false }).error, "cursor_expired")
        let restart = try request("read_session_events", extra: ["eventCursor": ["appEpoch": UUID().uuidString, "sequence": 0]])
        XCTAssertEqual(TerminalAgentToolService.perform(restart, registry: registry,
            snapshotSequence: 1, paired: { false }).error, "app_restarted")
    }

    func testLegacyToolStateDecodesWithoutNewFields() throws {
        let json = #"{"schemaVersion":1,"app":"QTerm","version":"1.248.0-rc1","snapshotSequence":1,"updatedAt":0,"sessionTunnelPresets":[],"tabs":[]}"#
        let state = try JSONDecoder().decode(TerminalToolState.self, from: Data(json.utf8))
        XCTAssertNil(state.eventCursor)
        XCTAssertNil(state.sessions)
    }

    func testPrivateBridgeWriterAtomicallyReplacesWithOwnerOnlyPermissions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qterm-private-write-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("response.json")
        try TerminalToolPrivateWriter.write(Data("first".utf8), to: destination)
        try TerminalToolPrivateWriter.write(Data("replacement".utf8), to: destination)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "replacement")
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["response.json"])
    }
}
