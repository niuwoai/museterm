import Foundation
import XCTest
@testable import museterm

final class TerminalRuntimeServiceTests: XCTestCase {
    func testExistingServiceDoesNotLaunchHelper() throws {
        let fixture = Fixture()
        fixture.filesAreMissing = false
        fixture.connect = { _ in }

        try fixture.ensureRunning()

        XCTAssertEqual(fixture.connections, 1)
        XCTAssertEqual(fixture.launches, 0)
        XCTAssertEqual(fixture.sleeps, 0)
    }

    func testCapabilityPublishedAfterMissingReadIsRevalidated() throws {
        let fixture = Fixture()
        fixture.connect = { state in
            if state.connections == 1 {
                // The first read failed before the other launcher published.
                state.filesAreMissing = false
                throw TerminalRuntimeConnectionError.invalidCapability
            }
        }

        try fixture.ensureRunning()

        XCTAssertEqual(fixture.connections, 2)
        XCTAssertEqual(fixture.launches, 0)
        XCTAssertEqual(fixture.sleeps, 0)
    }

    func testPublishedCapabilityCanPrecedeSocketReadiness() throws {
        let fixture = Fixture()
        fixture.connect = { state in
            switch state.connections {
            case 1:
                state.filesAreMissing = false
                throw TerminalRuntimeConnectionError.invalidCapability
            case 2: throw TerminalRuntimeConnectionError.unavailable
            default: break
            }
        }

        try fixture.ensureRunning()

        XCTAssertEqual(fixture.connections, 3)
        XCTAssertEqual(fixture.launches, 1)
        XCTAssertEqual(fixture.sleeps, 0)
    }

    func testPublishedMalformedCapabilityIsRejectedWithoutLaunching() {
        let fixture = Fixture()
        fixture.connect = { state in
            state.filesAreMissing = false
            throw TerminalRuntimeConnectionError.invalidCapability
        }

        assertFailure(.invalidCapability, fixture: fixture)

        XCTAssertEqual(fixture.connections, 2)
        XCTAssertEqual(fixture.launches, 0)
        XCTAssertEqual(fixture.sleeps, 0)
    }

    func testExistingDamagedOrIncompatibleEndpointIsRejectedImmediately() {
        for error in rejectedEndpointErrors {
            let fixture = Fixture()
            fixture.filesAreMissing = false
            fixture.connect = { _ in throw error }

            assertFailure(error, fixture: fixture)

            XCTAssertEqual(fixture.connections, 1, error.diagnosticCode)
            XCTAssertEqual(fixture.launches, 0, error.diagnosticCode)
            XCTAssertEqual(fixture.sleeps, 0, error.diagnosticCode)
        }
    }

    func testExitedLockContenderWaitsForWinningService() throws {
        let fixture = Fixture()
        fixture.helperIsRunning = false
        fixture.connect = { state in
            switch state.connections {
            case 1, 2: throw TerminalRuntimeConnectionError.invalidCapability
            case 3:
                state.filesAreMissing = false
                throw TerminalRuntimeConnectionError.invalidCapability
            default: break
            }
        }

        try fixture.ensureRunning()

        XCTAssertEqual(fixture.connections, 4)
        XCTAssertEqual(fixture.launches, 1)
        XCTAssertEqual(fixture.sleeps, 1)
        XCTAssertFalse(fixture.helperIsRunning)
    }

    func testDamagedOrIncompatibleEndpointDuringStartupIsRejectedImmediately() {
        for error in rejectedEndpointErrors {
            let fixture = Fixture()
            fixture.helperIsRunning = false
            fixture.connect = { state in
                if state.connections == 1 { throw TerminalRuntimeConnectionError.invalidCapability }
                state.filesAreMissing = false
                throw error
            }

            assertFailure(error, fixture: fixture)

            let expectedConnections = error.diagnosticCode == "invalid_capability" ? 3 : 2
            XCTAssertEqual(fixture.connections, expectedConnections, error.diagnosticCode)
            XCTAssertEqual(fixture.launches, 1, error.diagnosticCode)
            XCTAssertEqual(fixture.sleeps, 0, error.diagnosticCode)
        }
    }

    func testExitedHelperWithoutWinnerFailsOnlyAtDeadline() {
        let fixture = Fixture()
        fixture.helperIsRunning = false

        assertFailure(.unavailable, fixture: fixture)

        XCTAssertEqual(fixture.launches, 1)
        XCTAssertGreaterThan(fixture.connections, 2)
        XCTAssertGreaterThanOrEqual(fixture.uptime, TerminalRuntimeLimits.requestDeadline)
        XCTAssertLessThan(fixture.uptime, TerminalRuntimeLimits.requestDeadline + 0.1)
    }

    func testSlowHelperTimesOutWithoutStoppingIt() {
        let fixture = Fixture()

        assertFailure(.timedOut, fixture: fixture)

        XCTAssertEqual(fixture.launches, 1)
        XCTAssertGreaterThanOrEqual(fixture.uptime, TerminalRuntimeLimits.requestDeadline)
        XCTAssertTrue(fixture.helperIsRunning)
    }

    func testLaunchFailureIsPropagatedWithoutWaiting() {
        let fixture = Fixture()
        fixture.launchError = .launchFailed

        XCTAssertThrowsError(try fixture.ensureRunning()) { error in
            XCTAssertEqual(error as? FixtureError, .launchFailed)
        }

        XCTAssertEqual(fixture.connections, 1)
        XCTAssertEqual(fixture.launches, 1)
        XCTAssertEqual(fixture.sleeps, 0)
    }

    func testMissingArtifactsRemainDistinctFromUnsafeRootAndDanglingCapability() throws {
        let root = URL(fileURLWithPath: "/private/tmp/qrsvc-\(UUID().uuidString.prefix(12))", isDirectory: true)
        let filesAreMissing = TerminalRuntimeService.StartupOperations().startupFilesAreMissing
        XCTAssertTrue(filesAreMissing(root))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { XCTFail("Could not remove owned startup fixture") }
        }
        XCTAssertTrue(filesAreMissing(root))

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        XCTAssertFalse(filesAreMissing(root))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("ui-capability"),
            withDestinationURL: root.appendingPathComponent("unpublished"))
        XCTAssertFalse(filesAreMissing(root))
    }

    private var rejectedEndpointErrors: [TerminalRuntimeConnectionError] {
        [.invalidCapability, .incompatibleProtocol, .invalidResponse, .frameTooLarge, .serviceChanged, .rejected("unauthorized")]
    }

    private func assertFailure(_ expected: TerminalRuntimeConnectionError, fixture: Fixture,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try fixture.ensureRunning(), file: file, line: line) { error in
            XCTAssertEqual((error as? TerminalRuntimeConnectionError)?.diagnosticCode, expected.diagnosticCode,
                file: file, line: line)
        }
    }

    private enum FixtureError: Error { case launchFailed }

    private final class Fixture {
        let root = URL(fileURLWithPath: "/private/tmp/qrsvc-\(UUID().uuidString.prefix(12))", isDirectory: true)
        var filesAreMissing = true
        var helperIsRunning = true
        var connections = 0
        var launches = 0
        var sleeps = 0
        var uptime: TimeInterval = 0
        var launchError: FixtureError?
        var connect: (Fixture) throws -> Void = { _ in throw TerminalRuntimeConnectionError.unavailable }

        func ensureRunning() throws {
            let executable = root.appendingPathComponent("must-not-launch")
            let operations = TerminalRuntimeService.StartupOperations(connect: { root in
                XCTAssertEqual(root, self.root)
                self.connections += 1
                try self.connect(self)
            }, startupFilesAreMissing: { root in
                XCTAssertEqual(root, self.root)
                return self.filesAreMissing
            }, launch: { root, path in
                XCTAssertEqual(root, self.root)
                XCTAssertEqual(path, executable)
                self.launches += 1
                if let error = self.launchError { throw error }
                return { self.helperIsRunning }
            }, uptime: { self.uptime }, sleep: { interval in
                self.sleeps += 1
                self.uptime += interval
            })
            try TerminalRuntimeService.ensureRunning(root: root, executable: executable, operations: operations)
        }
    }
}
