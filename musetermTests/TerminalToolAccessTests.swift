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

    @MainActor
    func testToolBridgeWritesAreDisabledByDefault() {
        let suiteName = "TerminalToolAccessTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = TerminalPreferences(defaults: defaults)

        XCTAssertFalse(preferences.toolBridgeWritesEnabled)
    }
}
