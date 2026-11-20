import CryptoKit
import Darwin
import Foundation

nonisolated enum TerminalRuntimeService {
    // Ordinary application sessions are owned by the persistent service. Test
    // hosts keep explicit opt-in so legacy/UI fixtures cannot touch real state.
    static var isEnabled: Bool {
        #if DEBUG
        applicationActivation(arguments: ProcessInfo.processInfo.arguments,
            environment: ProcessInfo.processInfo.environment, bundleID: Bundle.main.bundleIdentifier)
        #else
        true
        #endif
    }
    #if DEBUG
    static func applicationActivation(arguments: [String], environment: [String: String], bundleID: String?) -> Bool {
        let testHost = environment["XCTestConfigurationFilePath"] != nil
            || bundleID?.hasPrefix("im.some.museterm.goaltests") == true
        return !testHost || testActivation(arguments: arguments, environment: environment, bundleID: bundleID)
    }

    /// Native UI tools cannot supply launch arguments. A signed QA bundle can
    /// instead declare this environment in its temporary LSEnvironment metadata.
    /// Never activate this route for a regular application or a shared root.
    static func testActivation(arguments: [String], environment: [String: String], bundleID: String?) -> Bool {
        if arguments.contains("-ui-testing-runtime") { return true }
        return bundleID?.hasPrefix("im.some.museterm.goaltests") == true
            && environment["MUSETERM_UI_TEST_RUNTIME"] == "1"
            && environment["MUSETERM_AGENT_TEST_TOOL_ROOT"]?.hasPrefix("/") == true
    }
    #endif
    static var rootDirectory: URL {
        let environment = ProcessInfo.processInfo.environment
        #if DEBUG
        let unitTest = environment["XCTestConfigurationFilePath"] != nil
            || Bundle.main.bundleIdentifier?.hasPrefix("im.some.museterm.goaltests") == true
        if let testRoot = environment["MUSETERM_AGENT_TEST_TOOL_ROOT"] ?? (unitTest ? "unit-\(ProcessInfo.processInfo.processIdentifier)" : nil) {
            let hash = SHA256.hash(data: Data(testRoot.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
            return URL(fileURLWithPath: "/private/tmp/qrt-ui-\(getuid())-\(hash)", isDirectory: true)
        }
        if let explicit = environment["MUSETERM_RUNTIME_ROOT"], explicit.hasPrefix("/") {
            return URL(fileURLWithPath: explicit, isDirectory: true)
        }
        #endif
        return MuseTermLegacyCompatibility.directory("Runtime")
    }

    static var executableURL: URL {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["MUSETERM_RUNTIME_HELPER_PATH"], path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        #endif
        return Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/museterm-runtime")
    }

    nonisolated struct StartupOperations {
        var connect: (URL) throws -> Void = { root in
            let connection = try TerminalRuntimeConnection(root: root)
            connection.close()
        }
        var startupFilesAreMissing: (URL) -> Bool = TerminalRuntimeService.startupFilesAreMissing
        var launch: (URL, URL) throws -> (() -> Bool) = TerminalRuntimeService.launch
        var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        var sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    }

    private static let startupPollInterval: TimeInterval = 0.05

    /// Run only off the main thread. A live incompatible service is never stopped
    /// or replaced. Racing launches are resolved by the helper's exclusive lock.
    static func ensureRunning(root: URL, executable: URL) throws {
        try ensureRunning(root: root, executable: executable, operations: StartupOperations())
    }

    static func ensureRunning(root: URL, executable: URL, operations: StartupOperations) throws {
        if try connectIfReady(root: root, operations: operations) { return }
        let isRunning = try operations.launch(root, executable)
        let deadline = operations.uptime() + TerminalRuntimeLimits.requestDeadline
        while operations.uptime() < deadline {
            if try connectIfReady(root: root, operations: operations) { return }
            // Our helper may have lost the exclusive lock to another launcher.
            // Its exit says nothing about the winning service's readiness.
            operations.sleep(startupPollInterval)
        }
        // Do not kill a slow-starting service: it may already own live terminals.
        throw isRunning() ? TerminalRuntimeConnectionError.timedOut : TerminalRuntimeConnectionError.unavailable
    }

    private static func connectIfReady(root: URL, operations: StartupOperations) throws -> Bool {
        let filesWereMissing = operations.startupFilesAreMissing(root)
        do {
            try operations.connect(root)
            return true
        } catch TerminalRuntimeConnectionError.unavailable { return false }
        catch TerminalRuntimeConnectionError.invalidCapability {
            guard filesWereMissing else { throw TerminalRuntimeConnectionError.invalidCapability }
            guard !operations.startupFilesAreMissing(root) else { return false }
            // Publication can race the failed read. Validate the newly visible
            // endpoint instead of applying the earlier missing-file diagnosis.
            do {
                try operations.connect(root)
                return true
            } catch TerminalRuntimeConnectionError.unavailable { return false }
        }
    }

    private static func startupFilesAreMissing(root: URL) -> Bool {
        var attributes = Darwin.stat()
        if lstat(root.path, &attributes) != 0 { return errno == ENOENT }
        guard attributes.st_uid == getuid(), attributes.st_mode & S_IFMT == S_IFDIR,
              attributes.st_mode & 0o077 == 0 else { return false }
        // lstat keeps a dangling symlink distinct from an unpublished capability.
        return lstat(root.appendingPathComponent("ui-capability").path, &attributes) != 0 && errno == ENOENT
    }

    private static func launch(root: URL, executable: URL) throws -> () -> Bool {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw TerminalRuntimeConnectionError.unavailable }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--root", root.path]
        // Infrastructure helpers must not inherit XCTest/DYLD injection or model
        // credentials from a GUI launched under a debugger. Terminal children
        // still receive their explicitly constructed launch environment.
        process.environment = ProcessInfo.processInfo.environment.filter {
            ["PATH", "HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL"].contains($0.key)
        }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return { process.isRunning }
    }
}
