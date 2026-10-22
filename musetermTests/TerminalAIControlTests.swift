import XCTest
@testable import museterm

final class TerminalAIControlTests: XCTestCase {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("qterm-ai-\(UUID())")
    }

    func testLeaseExcludesOtherOwnersAndCanBeRenewed() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tab = TerminalSession(sequence: 1)
        defer { tab.releaseAIControl(reason: "test_finished") }
        let start = Date()
        try tab.takeAIControl(owner: "first", now: start, archiveDirectory: directory)
        XCTAssertThrowsError(try tab.takeAIControl(owner: "second", archiveDirectory: directory))
        XCTAssertThrowsError(try tab.authorizeAIInput(owner: "second"))
        XCTAssertThrowsError(try tab.authorizeAIInput(owner: nil))
        XCTAssertThrowsError(try tab.renewAIControl(owner: "second"))
        try tab.renewAIControl(owner: "first", now: start.addingTimeInterval(60))
        tab.expireAIControlIfNeeded(now: start.addingTimeInterval(121))
        XCTAssertEqual(tab.aiLease?.owner, "first")
        XCTAssertEqual(tab.aiLease?.expiresAt, start.addingTimeInterval(180))
    }

    func testExpiredLeaseUnlocksAndRejectsDelayedWrites() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tab = TerminalSession(sequence: 1)
        let start = Date()
        try tab.takeAIControl(owner: "first", now: start, archiveDirectory: directory)
        tab.expireAIControlIfNeeded(now: start.addingTimeInterval(120))
        XCTAssertNil(tab.aiLease)
        XCTAssertThrowsError(try tab.authorizeAIInput(owner: "first"))
        XCTAssertThrowsError(try tab.authorizeAIInput(owner: nil))
        XCTAssertThrowsError(try tab.renewAIControl(owner: "first"))
    }

    func testHumanUnlockRequiresExplicitNewTakeover() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tab = TerminalSession(sequence: 1)
        try tab.takeAIControl(owner: "first", archiveDirectory: directory)
        tab.releaseAIControl(reason: "human_unlock")
        XCTAssertNil(tab.aiLease)
        XCTAssertThrowsError(try tab.authorizeAIInput(owner: "first"))
        try tab.takeAIControl(owner: "second", archiveDirectory: directory)
        defer { tab.releaseAIControl(reason: "test_finished") }
        XCTAssertNoThrow(try tab.authorizeAIInput(owner: "second"))
    }

    func testArchiveFailureDoesNotAcquireLock() throws {
        let directory = temporaryDirectory()
        try Data().write(to: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tab = TerminalSession(sequence: 1)
        XCTAssertThrowsError(try tab.takeAIControl(owner: "first", archiveDirectory: directory))
        XCTAssertNil(tab.aiLease)
        XCTAssertFalse(tab.aiRequiresTakeover)
    }

    func testArchiveRedactsSecretsAcrossInputChunksAndOmitsHiddenInput() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try TerminalAIArchive(tabID: UUID(), directory: directory)
        try archive.record(Array("export API_".utf8), echoEnabled: true)
        try archive.record(Array("KEY=example-sensitive-value\r".utf8), echoEnabled: true)
        try archive.record(Array("export PASSWORD='first-value remaining-sensitive-value'\r".utf8), echoEnabled: true)
        try archive.record(Array("hidden-password\r".utf8), echoEnabled: false)
        try archive.record(Array("pwd\r".utf8), echoEnabled: true)
        try archive.flush()
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil).first)
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.contains("example-sensitive-value"))
        XCTAssertFalse(text.contains("hidden-password"))
        XCTAssertFalse(text.contains("remaining-sensitive-value"))
        XCTAssertTrue(text.contains("[REDACTED]"))
        XCTAssertTrue(text.contains("hidden_input_omitted"))
        XCTAssertTrue(text.contains("pwd"))
        for line in text.split(separator: "\n") {
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(line.utf8)))
        }
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testArchiveFlushesPartialInputOnRelease() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let tab = TerminalSession(sequence: 1)
        try tab.takeAIControl(owner: "first", archiveDirectory: directory)
        try tab.archiveAIInput(Array("partial command".utf8), echoEnabled: true)
        tab.releaseAIControl(reason: "human_unlock")
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil).first)
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("partial command"))
        XCTAssertTrue(text.contains("human_unlock"))
    }

    func testFailedBackgroundInputNeverChangesSelectedTab() throws {
        let workspace = TerminalWorkspace(automaticallyStartProcesses: false)
        let target = try XCTUnwrap(workspace.selectedTab)
        let selected = workspace.newTab()
        XCTAssertThrowsError(try workspace.sendToolInput(to: target.id.uuidString, bytes: [0x0D]))
        XCTAssertEqual(workspace.selectedID, selected.id)
    }

    func testBackgroundPTYInputKeepsSelectionAndRejectsHumanInputWhileLocked() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = TerminalWorkspace(automaticallyStartProcesses: false)
        let target = workspace.newTab(profile: TerminalProfile(shell: .custom, customShellPath: "/bin/sh"))
        defer { target.terminate() }
        target.prewarm(preferences: nil)
        let deadline = Date().addingTimeInterval(10)
        while !target.hasRunningProcess && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(target.hasRunningProcess)
        let selected = workspace.newTab()
        try target.takeAIControl(owner: "first", archiveDirectory: directory)
        XCTAssertThrowsError(try target.controller.sendToolInput(bytes: Array("human\r".utf8)))
        _ = try workspace.sendToolInput(to: target.id.uuidString,
            bytes: Array("printf 'qterm_background_ok\\n'\r".utf8), owner: "first")
        XCTAssertEqual(workspace.selectedID, selected.id)
        target.releaseAIControl(reason: "human_unlock")
        XCTAssertThrowsError(try workspace.sendToolInput(to: target.id.uuidString, bytes: [0x0D], owner: "first"))
    }

    func testMultilinePrivateKeyIsOmitted() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = try TerminalAIArchive(tabID: UUID(), directory: directory)
        try archive.record(Array("-----BEGIN PRIVATE KEY-----\nprivate-body-value\n-----END PRIVATE KEY-----\n".utf8), echoEnabled: true)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil).first)
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.contains("private-body-value"))
        XCTAssertTrue(text.contains("private_key_input_omitted"))
    }
}
