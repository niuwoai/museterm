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
            || bundleID?.hasPrefix("im.some.qterm.goaltests") == true
        return !testHost || testActivation(arguments: arguments, environment: environment, bundleID: bundleID)
    }

    /// Native UI tools cannot supply launch arguments. A signed QA bundle can
    /// instead declare this environment in its temporary LSEnvironment metadata.
    /// Never activate this route for a regular application or a shared root.
    static func testActivation(arguments: [String], environment: [String: String], bundleID: String?) -> Bool {
        if arguments.contains("-ui-testing-runtime") { return true }
        return bundleID?.hasPrefix("im.some.qterm.goaltests") == true
            && environment["QTERM_UI_TEST_RUNTIME"] == "1"
            && environment["QTERM_AGENT_TEST_TOOL_ROOT"]?.hasPrefix("/") == true
    }
    #endif
    static var rootDirectory: URL {
        let environment = ProcessInfo.processInfo.environment
        #if DEBUG
        let unitTest = environment["XCTestConfigurationFilePath"] != nil
            || Bundle.main.bundleIdentifier?.hasPrefix("im.some.qterm.goaltests") == true
        if let testRoot = environment["QTERM_AGENT_TEST_TOOL_ROOT"] ?? (unitTest ? "unit-\(ProcessInfo.processInfo.processIdentifier)" : nil) {
            let hash = SHA256.hash(data: Data(testRoot.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
            return URL(fileURLWithPath: "/private/tmp/qrt-ui-\(getuid())-\(hash)", isDirectory: true)
        }
        if let explicit = environment["QTERM_RUNTIME_ROOT"], explicit.hasPrefix("/") {
            return URL(fileURLWithPath: explicit, isDirectory: true)
        }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/QTerm/Runtime", isDirectory: true)
    }

    static var executableURL: URL {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["QTERM_RUNTIME_HELPER_PATH"], path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        #endif
        return Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/qterm-runtime")
    }

    /// Run only off the main thread. A live incompatible service is never stopped
    /// or replaced. Racing launches are resolved by the helper's exclusive lock.
    static func ensureRunning(root: URL, executable: URL) throws {
        do {
            let existing = try TerminalRuntimeConnection(root: root)
            existing.close(); return
        } catch TerminalRuntimeConnectionError.incompatibleProtocol { throw TerminalRuntimeConnectionError.incompatibleProtocol }
        catch TerminalRuntimeConnectionError.invalidResponse { throw TerminalRuntimeConnectionError.invalidResponse }
        catch TerminalRuntimeConnectionError.invalidCapability {
            guard !FileManager.default.fileExists(atPath: root.appendingPathComponent("ui-capability").path) else {
                throw TerminalRuntimeConnectionError.invalidCapability
            }
        } catch TerminalRuntimeConnectionError.unavailable { /* No live socket; lock still protects races. */ }
        catch { throw error }
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
        let deadline = ProcessInfo.processInfo.systemUptime + TerminalRuntimeLimits.requestDeadline
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let connection = try? TerminalRuntimeConnection(root: root) { connection.close(); return }
            guard process.isRunning else { throw TerminalRuntimeConnectionError.unavailable }
            Thread.sleep(forTimeInterval: 0.05)
        }
        // Do not kill a slow-starting service: it may already own live terminals.
        throw TerminalRuntimeConnectionError.timedOut
    }
}
