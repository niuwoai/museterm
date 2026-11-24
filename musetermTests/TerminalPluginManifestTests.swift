import XCTest
@testable import museterm

final class TerminalPluginManifestTests: XCTestCase {
    func testRejectsMissingChineseIllegalPermissionAndWrongSchemaVersion() throws {
        let missing = try manifest(removing: "schemaVersion")
        XCTAssertTrue(issues(missing).contains { $0.path == "/museterm/schemaVersion" })

        var withoutChinese = example
        var museterm = withoutChinese["museterm"] as! [String: Any]
        museterm["displayName"] = ["en": "Deploy"]
        withoutChinese["museterm"] = museterm
        XCTAssertTrue(issues(withoutChinese).contains { $0.path == "/museterm/displayName" })

        var illegal = example
        var illegalManifest = illegal["museterm"] as! [String: Any]
        illegalManifest["permissions"] = ["palette", "pty.read"]
        illegal["museterm"] = illegalManifest
        XCTAssertTrue(issues(illegal).contains { $0.path == "/museterm/permissions/1" })

        var wrongVersion = example
        var versionManifest = wrongVersion["museterm"] as! [String: Any]
        versionManifest["schemaVersion"] = 2
        wrongVersion["museterm"] = versionManifest
        XCTAssertTrue(issues(wrongVersion).contains { $0.path == "/museterm/schemaVersion" })
    }

    func testReleaseDoesNotCoverItsOwnReleaseCandidate() {
        XCTAssertEqual(TerminalPluginManifest.versionRangeCovers(">=1.262.0", "1.262.0-rc2"), false)
        XCTAssertEqual(TerminalPluginManifest.versionRangeCovers(">=1.262.0-rc2", "1.262.0-rc2"), true)
        XCTAssertEqual(TerminalPluginManifest.versionRangeCovers("*", "1.262.0-rc2"), true)
    }

    func testDropdownDefaultMustBeOneOfTheChoices() {
        var package = example
        var manifest = package["museterm"] as! [String: Any]
        manifest["preferences"] = [[
            "name": "target",
            "type": "dropdown",
            "title": ["en": "Target", "zh-Hans": "目标"],
            "data": [[
                "title": ["en": "Staging", "zh-Hans": "预发"],
                "value": "staging",
            ]],
            "default": "production",
        ]]
        package["museterm"] = manifest
        XCTAssertTrue(issues(package).contains { $0.path == "/museterm/preferences/0/default" })
    }

    func testRecordingPayloadKeepsOnlyTheAllowlist() throws {
        let event = TerminalPluginRecordingEvent(
            id: "1", title: "Saved", eventCount: 2, durationMilliseconds: 10,
            hasProtectedInput: true, requiresUserAuthentication: false, allowsAutomationPlayback: true
        )
        let plugin = TerminalPlugin(
            id: "@example/ledger", directory: URL(fileURLWithPath: "/tmp"), displayName: "Ledger",
            version: "0.1.0", permissions: ["recording.observe"], commands: [], preferences: [],
            suggestExport: nil, recordingExport: "onRecording", enabled: true, source: "local",
            entry: "dist/index.js"
        )
        let request = try TerminalPluginRunner.requestObject(.recording(plugin: plugin, event: event))
        let payload = ((request["params"] as! [String: Any])["event"] as! [String: Any])["shortcut"] as! [String: Any]
        XCTAssertEqual(Set(payload.keys), Set(TerminalPluginRecording.allowedFields))
        XCTAssertNil(payload["events"])
        XCTAssertNil(payload["protectedBytesReference"])
    }

    func testSandboxDeniesVaultToolsKeychainAndNetwork() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let root = home
            .appendingPathComponent("Library/Caches/MuseTermPluginSandboxTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(root.path.hasPrefix(home.path + "/"))
        let plugin = root.appendingPathComponent("plugin", isDirectory: true)
        let scratch = root.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try Data("owned".utf8).write(to: plugin.appendingPathComponent("owned.txt"))
        let profile = scratch.appendingPathComponent("plugin.sb")
        let paths = TerminalPluginSandbox.Paths(
            pluginDirectory: plugin.path,
            temporaryDirectory: scratch.path,
            shortcutDirectory: root.appendingPathComponent("shortcuts").path,
            toolBridgeDirectory: root.appendingPathComponent("tools").path,
            homeDirectory: home.path
        )
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: paths.shortcutDirectory), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: paths.toolBridgeDirectory), withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: URL(fileURLWithPath: paths.shortcutDirectory).appendingPathComponent("protected-vault.key"))
        try Data("nope".utf8).write(to: root.appendingPathComponent("sibling.txt"))
        try TerminalPluginSandbox.profile(for: paths).write(to: profile, atomically: true, encoding: .utf8)

        XCTAssertEqual(try run(profile, ["/bin/cat", plugin.appendingPathComponent("owned.txt").path]).status, 0)
        XCTAssertNotEqual(try run(profile, ["/bin/cat", root.appendingPathComponent("sibling.txt").path]).status, 0)
        XCTAssertNotEqual(try run(profile, ["/bin/cat", paths.shortcutDirectory + "/protected-vault.key"]).status, 0)
        XCTAssertNotEqual(try run(profile, ["/bin/ls", paths.toolBridgeDirectory]).status, 0)
        XCTAssertNotEqual(try run(profile, ["/usr/bin/nc", "-z", "-G", "2", "example.com", "443"]).status, 0)
        let keychain = try run(profile, ["/usr/bin/security", "find-generic-password", "-s", "com.museterm.credentials"])
        XCTAssertNotEqual(keychain.status, 0)
    }

    func testPluginMessageRoundTripWithoutSandbox() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("museterm-plugin-run-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("dist"), withIntermediateDirectories: true)
        try Data(JSONSerialization.data(withJSONObject: example)).write(to: source.appendingPathComponent("package.json"))
        let script = """
        export async function deployStaging() {
          return { type: "message", title: "ready", body: "one" }
        }
        """
        try Data(script.utf8).write(to: source.appendingPathComponent("dist/index.js"))
        let store = TerminalPluginStore(directory: root.appendingPathComponent("Plugins"))
        try store.installLocal(from: source)
        store.setEnabled(true, id: "@example/museterm-deploy")
        let plugin = try XCTUnwrap(store.plugins.first)
        let tab = TerminalPluginTabContext(
            id: "tab", targetKind: "local", environment: "local", targetName: "", user: nil,
            host: nil, workingDirectory: nil, shell: nil
        )
        let node = nodeExecutable
        let result = try TerminalPluginRunner.run(
            .command(plugin: plugin, exportName: "deployStaging", commandID: "staging", tab: tab),
            nodeExecutable: URL(fileURLWithPath: node),
            sandbox: false
        )
        XCTAssertEqual(result, .message(title: "ready", body: "one"))
        try? FileManager.default.removeItem(at: root)
    }

    /// The host never looks Node up on `PATH`. Tests accept an override, then Homebrew, then `/usr/bin/node`.
    private var nodeExecutable: String {
        if let override = ProcessInfo.processInfo.environment["MUSETERM_TEST_NODE"], !override.isEmpty {
            return override
        }
        for candidate in ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
            where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return "/usr/bin/false"
    }

    private func run(_ profile: URL, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-f", profile.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, output)
    }

    func testCatalogInstallStaysDisabledAndKeepsTheDeclaredEntry() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("museterm-plugin-catalog-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = root.appendingPathComponent("catalog", isDirectory: true)
        let packageDirectory = catalog
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent("@example/museterm-deploy", isDirectory: true)
        try FileManager.default.createDirectory(at: packageDirectory.appendingPathComponent("dist"), withIntermediateDirectories: true)
        try Data(JSONSerialization.data(withJSONObject: example)).write(to: packageDirectory.appendingPathComponent("package.json"))
        try Data("export {}".utf8).write(to: packageDirectory.appendingPathComponent("dist/index.js"))
        let index = [["name": "@example/museterm-deploy", "version": "0.1.0", "description": "Deploy"]]
        try JSONSerialization.data(withJSONObject: index).write(to: catalog.appendingPathComponent("index.json"))

        let loaded = TerminalPluginCatalog.load(directory: catalog)
        XCTAssertEqual(loaded.plugins.map(\.name), ["@example/museterm-deploy"])
        let store = TerminalPluginStore(directory: root.appendingPathComponent("Plugins"))
        try store.installFromCatalog(
            packageName: "@example/museterm-deploy",
            version: "0.1.0",
            catalogDirectory: catalog,
            nodeExecutable: URL(fileURLWithPath: nodeExecutable)
        )
        let plugin = try XCTUnwrap(store.plugins.first)
        XCTAssertEqual(plugin.enabled, false)
        XCTAssertEqual(plugin.source, "catalog:0.1.0")
        XCTAssertEqual(plugin.entry, "dist/index.js")
        XCTAssertTrue(FileManager.default.fileExists(atPath: plugin.entryURL.path))
    }

    func testLocalInstallStaysDisabledUntilEnabled() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("museterm-plugin-test-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: example)
        try data.write(to: source.appendingPathComponent("package.json"))
        let store = TerminalPluginStore(directory: root.appendingPathComponent("Plugins"))
        try store.installLocal(from: source)
        XCTAssertEqual(store.plugins.map(\.enabled), [false])
        store.setEnabled(true, id: "@example/museterm-deploy")
        XCTAssertEqual(store.plugins.map(\.enabled), [true])
        try? FileManager.default.removeItem(at: root)
    }

    private func issues(_ value: [String: Any]) -> [TerminalPluginIssue] {
        switch TerminalPluginManifest.read(package: value, appVersion: "1.263.0-rc1") {
        case .success: return []
        case .failure(let failure): return failure.issues
        }
    }

    private func manifest(removing key: String) throws -> [String: Any] {
        var value = example
        var manifest = value["museterm"] as! [String: Any]
        manifest.removeValue(forKey: key)
        value["museterm"] = manifest
        return value
    }

    private var example: [String: Any] {
        [
            "name": "@example/museterm-deploy",
            "version": "0.1.0",
            "museterm": [
                "schemaVersion": 1,
                "engines": ["museterm": ">=1.263.0-rc1"],
                "entry": "dist/index.js",
                "displayName": ["en": "Deploy", "zh-Hans": "部署"],
                "permissions": ["palette", "terminal.fill"],
                "commands": [[
                    "id": "staging",
                    "title": ["en": "Deploy staging", "zh-Hans": "部署到预发"],
                    "export": "deployStaging",
                ]],
            ] as [String: Any],
        ]
    }
}
