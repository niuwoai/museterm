import CryptoKit
import Darwin
import Foundation

private enum ProbeFailure: String, Error { case invalidArguments, failedAssertion, timedOut, missingSession }

@main
struct RuntimeConnectionProbe {
    static func require(_ condition: Bool) throws { if !condition { throw ProbeFailure.failedAssertion } }

    static func wait(_ condition: () throws -> Bool) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while try !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw ProbeFailure.timedOut }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    static func scoped(_ info: TerminalRuntimeSessionInfo, action: TerminalRuntimeAction) -> TerminalRuntimeRequest {
        var request = TerminalRuntimeRequest(action: action)
        request.sessionID = info.id; request.generation = info.generation
        request.controlEpoch = info.controlEpoch; request.inputSequence = info.nextInputSequence
        return request
    }

    static func main() throws {
        guard CommandLine.arguments.count == 3 else { throw ProbeFailure.invalidArguments }
        let binary = CommandLine.arguments[1]
        let reportPrefix = CommandLine.arguments[2]
        let root = URL(fileURLWithPath: "/private/tmp/qrc-\(UUID().uuidString.prefix(12))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let server = Process()
        server.executableURL = URL(fileURLWithPath: binary)
        server.arguments = ["--root", root.path]
        server.standardInput = FileHandle.nullDevice
        server.standardOutput = FileHandle.nullDevice
        server.standardError = FileHandle.nullDevice
        var checks: [String] = []
        var failure: String?
        do {
            try server.run()
            try wait { FileManager.default.fileExists(atPath: root.appendingPathComponent("ui-capability").path) }
            var connection = try TerminalRuntimeConnection(root: root)
            let hello = try connection.request(.init(action: .hello))
            try require(hello.version == AppVersion.value)
            checks.append("actual_swift_client_handshake_version_and_private_capability")
            var create = TerminalRuntimeRequest(action: .create)
            create.launch = .init(executable: "/bin/sh", arguments: ["-i"],
                environment: ["PATH": "/usr/bin:/bin", "HOME": root.path, "TERM": "xterm-256color"], directory: root.path)
            guard var info = try connection.request(create).session else { throw ProbeFailure.missingSession }
            var input = scoped(info, action: .input)
            input.source = .human; input.data = Data("stty -echo; printf '__SWIFT_CLIENT_READY\\n'\n".utf8)
            guard let afterInput = try connection.request(input).session else { throw ProbeFailure.missingSession }
            info = afterInput
            var output = Data()
            var cursor: TerminalRuntimeOutputCursor?
            try wait {
                var read = scoped(info, action: .read); read.after = cursor
                let response = try connection.request(read)
                output.append(response.data ?? Data()); cursor = response.cursor
                return String(decoding: output, as: UTF8.self).contains("__SWIFT_CLIENT_READY\r\n")
            }
            connection.close()
            connection = try TerminalRuntimeConnection(root: root)
            let restored = try connection.request(.init(action: .list)).sessions?.first { $0.id == info.id }
            try require(restored?.pid == info.pid && restored?.running == true)
            checks.append("swift_client_disconnect_reconnect_keeps_same_pid")
            input = scoped(info, action: .input); input.source = .human
            input.data = Data("printf '__SWIFT_CLIENT_SECOND\\n'\n".utf8)
            let accepted = try connection.request(input)
            try require(accepted.echoEnabled == false)
            guard let latest = accepted.session else { throw ProbeFailure.missingSession }
            info = latest
            try wait {
                var read = scoped(info, action: .read); read.after = cursor
                let response = try connection.request(read)
                output.append(response.data ?? Data()); cursor = response.cursor
                return String(decoding: output, as: UTF8.self).contains("__SWIFT_CLIENT_SECOND\r\n")
            }
            checks.append("swift_client_real_input_echo_and_output_cursor")
            var oversized = scoped(info, action: .input); oversized.source = .human
            oversized.data = Data(count: TerminalRuntimeLimits.maximumFrameBytes)
            do { _ = try connection.request(oversized); throw ProbeFailure.failedAssertion }
            catch TerminalRuntimeConnectionError.frameTooLarge {}
            _ = try connection.request(.init(action: .list))
            checks.append("oversized_request_is_rejected_before_socket_write")

            var quietCreate = TerminalRuntimeRequest(action: .create)
            quietCreate.launch = .init(executable: "/bin/sh", arguments: ["-c", "printf '__QUIET_READY'; sleep 30"],
                environment: ["PATH": "/usr/bin:/bin", "HOME": root.path, "TERM": "xterm-256color"], directory: root.path)
            guard let quiet = try connection.request(quietCreate).session else { throw ProbeFailure.missingSession }
            var quietCursor: TerminalRuntimeOutputCursor?
            try wait {
                var read = scoped(quiet, action: .read); read.after = quietCursor
                let response = try connection.request(read); quietCursor = response.cursor
                return String(decoding: response.data ?? Data(), as: UTF8.self).contains("__QUIET_READY")
            }
            let subscription = try TerminalRuntimeConnection(root: root)
            var subscribe = scoped(quiet, action: .subscribe); subscribe.after = quietCursor
            _ = try subscription.request(subscribe)
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { subscription.cancel() }
            do { _ = try subscription.next(id: subscribe.id, timeout: 3); throw ProbeFailure.failedAssertion }
            catch TerminalRuntimeConnectionError.cancelled {}
            subscription.close()
            try require(try connection.request(.init(action: .list)).sessions?.contains { $0.id == quiet.id && $0.running } == true)
            checks.append("cross_executor_cancellation_does_not_close_pty")

            let capability = root.appendingPathComponent("ui-capability")
            let saved = root.appendingPathComponent("saved-capability")
            try FileManager.default.moveItem(at: capability, to: saved)
            try FileManager.default.createSymbolicLink(at: capability, withDestinationURL: saved)
            do { _ = try TerminalRuntimeConnection(root: root); throw ProbeFailure.failedAssertion }
            catch TerminalRuntimeConnectionError.invalidCapability {}
            try FileManager.default.removeItem(at: capability)
            try FileManager.default.moveItem(at: saved, to: capability)
            checks.append("capability_symlink_is_rejected")
            _ = try connection.request(scoped(info, action: .close))
            _ = try connection.request(scoped(quiet, action: .close))
            connection.close()
        } catch { failure = String(describing: error) }

        // Clean up only sessions owned by our own private test service.
        if let cleanup = try? TerminalRuntimeConnection(root: root) {
            if let sessions = try? cleanup.request(.init(action: .list)).sessions {
                for info in sessions { _ = try? cleanup.request(scoped(info, action: .close)) }
            }
            cleanup.close()
            Thread.sleep(forTimeInterval: 0.1)
        }
        if server.isRunning { server.terminate(); server.waitUntilExit() }
        let passed = failure == nil
        let hash = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: binary))).map { String(format: "%02x", $0) }.joined()
        let report: [String: Any] = ["passed": passed, "failure": failure as Any? ?? NSNull(), "checks": checks,
            "backendSHA256": hash, "version": AppVersion.value, "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "scope": "生产 Swift 连接器对真实独立后台；尚未接 NSView/UI 恢复", "fixtureDirectory": passed ? NSNull() : root.path as Any]
        let prefix = URL(fileURLWithPath: reportPrefix)
        try FileManager.default.createDirectory(at: prefix.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: reportPrefix + ".json"))
        let markdown = ["# Swift 后台连接器验证", "", "通过：\(passed)", "失败：\(failure ?? "无")", ""] + checks.map { "- \($0)" }
        try (markdown.joined(separator: "\n") + "\n").write(toFile: reportPrefix + ".md", atomically: true, encoding: .utf8)
        if passed { try FileManager.default.removeItem(at: root) }
        print("Runtime connection probe passed: \(passed); report: \(reportPrefix).json")
        if !passed { exit(1) }
    }
}
