import XCTest
@testable import museterm

#if DEBUG
final class TerminalToolAccessFixtureTests: XCTestCase {
    private func fixture() throws -> (URL, URL) {
        let parent = URL(fileURLWithPath: "/private/tmp/museterm-native-qa-fixture-\(UUID())")
        let root = parent.appendingPathComponent("Tools", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let file = root.appendingPathComponent(TerminalToolAccessTestFixture.fileName)
        let data = try JSONEncoder().encode(TerminalToolAccessTestFixture.Credentials(
            clientID: "museterm-qa-fixture", token: String(repeating: "a", count: 64)))
        try TerminalToolPrivateWriter.write(data, to: file)
        return (parent, root)
    }

    func testPrivateFixtureCredentialsCanBeRead() throws {
        let (parent, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: parent) }
        XCTAssertEqual(try TerminalToolAccessTestFixture.load(root: root).clientID, "museterm-qa-fixture")
    }

    func testBroadPermissionsOrSymlinkAreRejected() throws {
        let (parent, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: parent) }
        let file = root.appendingPathComponent(TerminalToolAccessTestFixture.fileName)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertThrowsError(try TerminalToolAccessTestFixture.load(root: root))
        let moved = root.appendingPathComponent("private-credentials.json")
        try FileManager.default.moveItem(at: file, to: moved)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: moved.path)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: moved)
        XCTAssertThrowsError(try TerminalToolAccessTestFixture.load(root: root))
    }

    func testRegularClientIdentityAndOversizedFixtureAreRejected() throws {
        let (parent, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: parent) }
        let file = root.appendingPathComponent(TerminalToolAccessTestFixture.fileName)
        let data = try JSONEncoder().encode(TerminalToolAccessTestFixture.Credentials(
            clientID: "museterm-cli", token: String(repeating: "a", count: 64)))
        try TerminalToolPrivateWriter.write(data, to: file)
        XCTAssertThrowsError(try TerminalToolAccessTestFixture.load(root: root))
        try TerminalToolPrivateWriter.write(Data(repeating: 65, count: 2_000), to: file)
        XCTAssertThrowsError(try TerminalToolAccessTestFixture.load(root: root))
    }

    func testPublicParentOrLinkedToolDirectoryAreRejected() throws {
        let (parent, root) = try fixture()
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path)
        XCTAssertThrowsError(try TerminalToolAccessTestFixture.load(root: root))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
        let moved = parent.appendingPathComponent("ActualTools")
        try FileManager.default.moveItem(at: root, to: moved)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: moved)
        XCTAssertThrowsError(try TerminalToolAccessTestFixture.load(root: root))
    }
}
#endif
