import XCTest
@testable import museterm

final class TerminalToolAccessTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MuseTermKeychain._useTestStorage(true)
    }

    override func tearDown() {
        MuseTermKeychain._useTestStorage(false)
        super.tearDown()
    }

    func testClientTokenMustMatchKeychainGrant() {
        XCTAssertTrue(
            MuseTermKeychain.save(
                "expected-token",
                account: "test-client",
                serviceName: TerminalToolAccess.keychainServiceName
            )
        )

        XCTAssertTrue(
            TerminalToolAccess.authorizes(
                clientID: "test-client",
                token: "expected-token"
            )
        )
        XCTAssertFalse(
            TerminalToolAccess.authorizes(
                clientID: "test-client",
                token: "wrong-token"
            )
        )
        XCTAssertFalse(
            TerminalToolAccess.authorizes(
                clientID: "../test-client",
                token: "expected-token"
            )
        )
    }

    func testRevokingClientRemovesGrant() {
        XCTAssertTrue(TerminalToolAccess.pair(clientID: "test-client"))
        XCTAssertTrue(TerminalToolAccess.isPaired(clientID: "test-client"))

        TerminalToolAccess.revoke(clientID: "test-client")

        XCTAssertFalse(TerminalToolAccess.isPaired(clientID: "test-client"))
    }

    func testRenamedClientCanUseExistingGrantUntilRevoked() {
        let legacy = MuseTermLegacyCompatibility.legacyClientID
        XCTAssertTrue(MuseTermKeychain.save("legacy-test-token", account: legacy,
            serviceName: TerminalToolAccess.keychainServiceName))
        XCTAssertTrue(TerminalToolAccess.isPaired())
        XCTAssertTrue(TerminalToolAccess.authorizes(clientID: TerminalToolAccess.builtInClientID,
            token: "legacy-test-token"))
        TerminalToolAccess.revoke()
        XCTAssertFalse(TerminalToolAccess.isPaired())
        XCTAssertFalse(TerminalToolAccess.authorizes(clientID: legacy, token: "legacy-test-token"))
    }

    func testPairingRenamedClientInvalidatesLegacyGrant() {
        let legacy = MuseTermLegacyCompatibility.legacyClientID
        XCTAssertTrue(MuseTermKeychain.save("legacy-test-token", account: legacy,
            serviceName: TerminalToolAccess.keychainServiceName))
        XCTAssertTrue(TerminalToolAccess.pair())
        XCTAssertTrue(TerminalToolAccess.isPaired())
        XCTAssertFalse(TerminalToolAccess.authorizes(clientID: TerminalToolAccess.builtInClientID,
            token: "legacy-test-token"))
        XCTAssertFalse(TerminalToolAccess.authorizes(clientID: legacy, token: "legacy-test-token"))
    }

    @MainActor
    func testToolBridgeWritesAreDisabledByDefault() {
        let suiteName = "TerminalToolAccessTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = TerminalPreferences(defaults: defaults)

        XCTAssertFalse(preferences.toolBridgeWritesEnabled)
    }

    func testStateWriteThrottleCoalescesRapidContentChanges() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        var throttle = TerminalToolStateWriteThrottle(minimumInterval: 2)

        XCTAssertTrue(throttle.shouldWrite(signature: 1, force: false, now: start))
        XCTAssertFalse(
            throttle.shouldWrite(
                signature: 2,
                force: false,
                now: start.addingTimeInterval(0.35)
            )
        )
        XCTAssertTrue(
            throttle.shouldWrite(
                signature: 3,
                force: false,
                now: start.addingTimeInterval(2)
            )
        )
    }

    func testStateWriteThrottleLetsRequestsForceImmediateRefresh() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        var throttle = TerminalToolStateWriteThrottle(minimumInterval: 2)

        XCTAssertTrue(throttle.shouldWrite(signature: 1, force: false, now: start))
        XCTAssertTrue(
            throttle.shouldWrite(
                signature: 1,
                force: true,
                now: start.addingTimeInterval(0.1)
            )
        )
    }
}
