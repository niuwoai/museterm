import Foundation
import XCTest
@testable import museterm

final class ContextCommandLearningTests: XCTestCase {
    func testShellIntegrationParserReadsExecutionContext() throws {
        let parser = TerminalShellIntegrationParser()
        let marker = "\u{1B}]777;MuseTerm;context=2f746d702f70726f6a656374,726f636b79,501,6d61632e6c6f63616c,2f62696e2f7a7368\u{7}"

        let event = try XCTUnwrap(parser.accept(Array(marker.utf8)[...]).first)
        guard case .executionContext(let context) = event else {
            return XCTFail("Expected an execution context event")
        }
        XCTAssertEqual(context.workingDirectory, "/tmp/project")
        XCTAssertEqual(context.user, "rocky")
        XCTAssertEqual(context.uid, 501)
        XCTAssertEqual(context.host, "mac.local")
        XCTAssertEqual(context.shell, "/bin/zsh")
    }

    func testCommandBecomesDiscoverableAfterThreeRunsInSameContext() throws {
        let context = localContext(directory: "/tmp/project")
        let index = LearnedCommandIndex()

        for offset in 0..<3 {
            index.observe(
                block: completedBlock(command: "yarn test", exitCode: offset == 1 ? 1 : 0),
                context: context,
                now: Date(timeIntervalSince1970: TimeInterval(100 + offset * 120))
            )
        }

        let record = try XCTUnwrap(index.records.first)
        XCTAssertEqual(record.observationCount, 3)
        XCTAssertEqual(record.successCount, 2)
        XCTAssertEqual(record.failureCount, 1)
        XCTAssertEqual(record.category, .test)
        XCTAssertTrue(record.isDiscoverable)
    }

    func testLearningSeparatesSameCommandByDirectory() {
        let index = LearnedCommandIndex()
        let block = completedBlock(command: "git status", exitCode: 0)

        index.observe(block: block, context: localContext(directory: "/tmp/alpha"))
        index.observe(block: block, context: localContext(directory: "/tmp/beta"))

        XCTAssertEqual(index.records.count, 2)
        XCTAssertNotEqual(index.records[0].id, index.records[1].id)
    }

    func testLearningSeparatesSameCommandByEffectiveUser() {
        let index = LearnedCommandIndex()
        let block = completedBlock(command: "git status", exitCode: 0)
        var rootContext = localContext(directory: "/tmp")
        rootContext.user = "root"
        var deployContext = rootContext
        deployContext.user = "deploy"

        index.observe(block: block, context: rootContext)
        index.observe(block: block, context: deployContext)

        XCTAssertEqual(index.records.count, 2)
        XCTAssertNotEqual(index.records[0].id, index.records[1].id)
    }

    func testLearningRejectsSensitiveDangerousAndContextOnlyCommands() {
        let index = LearnedCommandIndex()
        let context = localContext(directory: "/tmp/project")

        XCTAssertNil(index.observe(block: completedBlock(command: "export API_TOKEN=secret", exitCode: 0), context: context))
        XCTAssertNil(index.observe(block: completedBlock(command: "rm -rf /", exitCode: 0), context: context))
        XCTAssertNil(index.observe(block: completedBlock(command: "cd /tmp", exitCode: 0), context: context))
        XCTAssertTrue(index.records.isEmpty)
    }

    func testRapidRepeatedFailuresCountOnce() throws {
        let index = LearnedCommandIndex()
        let context = localContext(directory: "/tmp/project")
        let failure = completedBlock(command: "yarn test", exitCode: 1)

        index.observe(block: failure, context: context, now: Date(timeIntervalSince1970: 100))
        index.observe(block: failure, context: context, now: Date(timeIntervalSince1970: 120))

        XCTAssertEqual(try XCTUnwrap(index.records.first).observationCount, 1)
    }

    func testLearningRejectsInferredContext() {
        let index = LearnedCommandIndex()
        var context = localContext(directory: "/tmp/project")
        context.confidence = .inferred

        XCTAssertNil(
            index.observe(
                block: completedBlock(command: "yarn test", exitCode: 0),
                context: context
            )
        )
        XCTAssertTrue(index.records.isEmpty)
    }

    func testLearnedCommandStoreRoundTripsContext() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("museterm-learned-command-tests-\(UUID().uuidString)", isDirectory: true)
        let previous = LearnedCommandStore._setTestDirectoryOverride(directory)
        defer {
            _ = LearnedCommandStore._setTestDirectoryOverride(previous)
            try? FileManager.default.removeItem(at: directory)
        }

        let context = localContext(directory: "/tmp/project")
        let index = LearnedCommandIndex()
        index.observe(block: completedBlock(command: "git status", exitCode: 0), context: context)
        LearnedCommandStore.save(index.records)

        let restored = try XCTUnwrap(LearnedCommandStore.load().first)
        XCTAssertEqual(restored.command, "git status")
        XCTAssertEqual(restored.context, context)
    }

    func testRecordedShortcutKeepsExecutionContext() throws {
        let recorder = TerminalShortcutRecorder(startedAt: Date(timeIntervalSince1970: 100))
        recorder.record(data: Array("git status\r".utf8), echoEnabled: true, now: Date(timeIntervalSince1970: 101))
        let context = localContext(directory: "/tmp/project")

        let shortcut = try XCTUnwrap(
            recorder.finish(
                title: "Status",
                executionContext: context,
                finishedAt: Date(timeIntervalSince1970: 102)
            )
        )

        XCTAssertEqual(shortcut.executionContext, context)
    }

    func testLearnedCommandCreatesNewLocalTabAtRecordedDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("museterm-context-run-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let workspace = TerminalWorkspace(automaticallyStartProcesses: false, profileStore: nil)
        let originalTabCount = workspace.tabs.count
        let record = learnedRecord(context: localContext(directory: directory.path))

        try workspace.executeLearnedCommand(record, sshProfiles: [])

        XCTAssertEqual(workspace.tabs.count, originalTabCount + 1)
        XCTAssertEqual(workspace.selectedTab?.launchConfiguration.localStartDirectory, directory.path)
    }

    func testLearnedCommandCreatesNewTabForExactSSHProfile() throws {
        var profile = SSHConnectionProfile(name: "Production", host: "prod.example.com", user: "deploy")
        profile.port = 2222
        var context = TerminalExecutionContext.inferred(
            launchConfiguration: .ssh(profile),
            currentDirectory: "/srv/app",
            shellName: "bash"
        )
        context.confidence = .observed
        let workspace = TerminalWorkspace(automaticallyStartProcesses: false, profileStore: nil)

        try workspace.executeLearnedCommand(learnedRecord(context: context), sshProfiles: [profile])

        guard case .ssh(let launchedProfile) = try XCTUnwrap(workspace.selectedTab).launchConfiguration else {
            return XCTFail("Expected a new SSH tab")
        }
        XCTAssertEqual(launchedProfile.id, profile.id)
        XCTAssertEqual(launchedProfile.host, "prod.example.com")
        XCTAssertEqual(launchedProfile.port, 2222)
        XCTAssertTrue(launchedProfile.remoteShellIntegrationEnabled)
    }

    func testDifferentEffectiveUserBuildsSudoContextCommand() {
        var context = localContext(directory: "/srv/app one")
        context.user = "deploy"

        let command = TerminalSession.privilegedCommand("git status", context: context)

        XCTAssertTrue(command.hasPrefix("sudo -iu 'deploy' sh -lc '"))
        XCTAssertTrue(command.contains("cd -- "))
        XCTAssertTrue(command.contains("/srv/app one"))
        XCTAssertTrue(command.contains("git status"))
        XCTAssertTrue(command.hasSuffix("\r"))
        XCTAssertFalse(command.contains("\n"))
    }

    private func localContext(directory: String) -> TerminalExecutionContext {
        TerminalExecutionContext(
            targetKind: .local,
            targetID: nil,
            targetName: "Local",
            targetFingerprint: "local:system",
            workingDirectory: directory,
            user: "tester",
            uid: 501,
            host: "mac.local",
            port: nil,
            shell: "/bin/zsh",
            confidence: .observed,
            capturedAt: Date(timeIntervalSince1970: 100)
        )
    }

    private func completedBlock(command: String, exitCode: Int32) -> TerminalCommandBlock {
        TerminalCommandBlock(
            id: UUID(),
            command: command,
            workingDirectory: "/tmp/project",
            startedAt: Date(timeIntervalSince1970: 100),
            endedAt: Date(timeIntervalSince1970: 101),
            exitCode: exitCode,
            outputTail: "",
            outputCharacterCount: 0,
            outputSummary: nil,
            isInteractive: false,
            commandStartSource: .shellIntegration,
            completionSource: .shellIntegration
        )
    }

    private func learnedRecord(context: TerminalExecutionContext) -> LearnedCommandRecord {
        LearnedCommandRecord(
            id: LearnedCommandIndex.recordID(command: "git status", context: context),
            command: "git status",
            context: context,
            category: .git,
            observationCount: 3,
            successCount: 3,
            failureCount: 0,
            firstSeenAt: Date(timeIntervalSince1970: 100),
            lastSeenAt: Date(timeIntervalSince1970: 300),
            lastFailureAt: nil,
            lastExecutedAt: nil,
            isPinned: false,
            isDismissed: false
        )
    }
}
