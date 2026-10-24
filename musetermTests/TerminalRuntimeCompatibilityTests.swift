import Foundation
import XCTest
@testable import museterm

@MainActor
final class TerminalRuntimeCompatibilityTests: XCTestCase {
    func testIncompatibleLivePeerDoesNotReplaceOriginalProcess() throws {
        try verifyRejectedPeer("protocol", expected: "incompatible_protocol")
    }

    func testMalformedLivePeerDoesNotReplaceOriginalProcess() throws {
        try verifyRejectedPeer("malformed", expected: "invalid_response")
    }

    func testWrongResponseIdentityDoesNotReplaceOriginalProcess() throws {
        try verifyRejectedPeer("identity", expected: "invalid_response")
    }

    func testOversizedLivePeerDoesNotReplaceOriginalProcess() throws {
        try verifyRejectedPeer("oversized", expected: "frame_too_large")
    }

    func testChangedServiceEpochClosesClientWithoutReplacingOriginalProcess() throws {
        let fixture = try Fixture()
        defer { fixture.stop() }
        let proxy = try fixture.startProxy("epoch")
        let connection = try TerminalRuntimeConnection(root: proxy)
        defer { connection.close() }
        XCTAssertThrowsError(try connection.request(.init(action: .list))) { error in
            XCTAssertEqual((error as? TerminalRuntimeConnectionError)?.diagnosticCode, "service_changed")
        }
        XCTAssertThrowsError(try connection.request(.init(action: .list)))
        try fixture.verifyOriginalProcessStillAcceptsInput()
        try fixture.verifyProxyOnlyReceived(["hello", "list"])
    }

    private func verifyRejectedPeer(_ mode: String, expected: String) throws {
        let fixture = try Fixture()
        defer { fixture.stop() }
        let proxy = try fixture.startProxy(mode)
        // A missing executable is deliberate: a fallback launch would yield a
        // different error, instead of the incompatible/corrupt peer diagnosis.
        XCTAssertThrowsError(try TerminalRuntimeService.ensureRunning(root: proxy,
            executable: fixture.root.appendingPathComponent("must-not-launch"))) { error in
            XCTAssertEqual((error as? TerminalRuntimeConnectionError)?.diagnosticCode, expected)
        }
        try fixture.verifyOriginalProcessStillAcceptsInput()
        try fixture.verifyProxyOnlyReceived(["hello"])
    }

    private final class Fixture {
        let root: URL
        private let service = Process()
        private var proxy: Process?
        private var connection: TerminalRuntimeConnection?
        private var original: TerminalRuntimeSessionInfo?
        private var cursor: TerminalRuntimeOutputCursor?

        init() throws {
            root = URL(fileURLWithPath: "/private/tmp/qrcmp-\(UUID().uuidString.prefix(12))", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            do {
                service.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/qterm-runtime")
                service.arguments = ["--root", root.path]
                service.environment = ["PATH": "/usr/bin:/bin", "HOME": root.path, "TMPDIR": root.path]
                service.standardInput = FileHandle.nullDevice
                service.standardOutput = FileHandle.nullDevice
                service.standardError = FileHandle.nullDevice
                try service.run()
                try wait { FileManager.default.fileExists(atPath: self.root.appendingPathComponent("ui-capability").path) }
                let connection = try TerminalRuntimeConnection(root: root)
                self.connection = connection
                var request = TerminalRuntimeRequest(action: .create)
                request.launch = .init(executable: "/bin/sh", arguments: ["-c",
                    "stty sane echo; printf '__COMPAT_READY\\n'; while IFS= read -r line; do eval \"$line\"; done"],
                    environment: ["PATH": "/usr/bin:/bin", "HOME": root.path], directory: root.path)
                original = try XCTUnwrap(connection.request(request).session)
                var output = ""
                try wait {
                    var read = self.scoped(.read)
                    read.after = self.cursor
                    let response = try connection.request(read)
                    self.cursor = response.cursor
                    output += String(decoding: response.data ?? Data(), as: UTF8.self)
                    return output.contains("__COMPAT_READY\r\n")
                }
            } catch { stop(); throw error }
        }

        func startProxy(_ mode: String) throws -> URL {
            let directory = root.appendingPathComponent("proxy", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            let capability = directory.appendingPathComponent("ui-capability")
            try Data(contentsOf: root.appendingPathComponent("ui-capability")).write(to: capability)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: capability.path)
            let process = Process()
            proxy = process
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ruby")
            process.arguments = ["-e", Self.proxyScript, root.path, directory.path, mode,
                String(TerminalRuntimeLimits.maximumResponseBytes)]
            process.environment = ["PATH": "/usr/bin:/bin", "HOME": root.path]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            try wait { FileManager.default.fileExists(atPath: directory.appendingPathComponent("runtime.sock").path) }
            return directory
        }

        func verifyOriginalProcessStillAcceptsInput() throws {
            let connection = try XCTUnwrap(connection)
            let before = try XCTUnwrap(original)
            let current = try XCTUnwrap(connection.request(.init(action: .list)).sessions?.first)
            XCTAssertEqual(current.id, before.id)
            XCTAssertEqual(current.pid, before.pid)
            XCTAssertEqual(current.generation, before.generation)
            XCTAssertTrue(current.running)
            var input = scoped(.input)
            input.inputSequence = current.nextInputSequence
            input.source = .human
            input.data = Data("printf '\\n__COMPAT_AFTER_BAD_PEER\\n'\n".utf8)
            _ = try connection.request(input)
            var output = ""
            try wait {
                var read = self.scoped(.read)
                read.after = self.cursor
                let response = try connection.request(read)
                self.cursor = response.cursor
                output += String(decoding: response.data ?? Data(), as: UTF8.self)
                return output.contains("\r\n__COMPAT_AFTER_BAD_PEER\r\n")
            }
        }

        func verifyProxyOnlyReceived(_ actions: [String]) throws {
            let path = root.appendingPathComponent("proxy/actions.json")
            try wait { FileManager.default.fileExists(atPath: path.path) }
            let observed = try JSONDecoder().decode([String].self, from: Data(contentsOf: path))
            XCTAssertEqual(observed, actions, "Rejected endpoint must receive no create/input/close request")
        }

        private func scoped(_ action: TerminalRuntimeAction) -> TerminalRuntimeRequest {
            var value = TerminalRuntimeRequest(action: action)
            value.sessionID = original?.id
            value.generation = original?.generation
            value.controlEpoch = original?.controlEpoch
            return value
        }

        private func wait(_ predicate: () throws -> Bool) throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 8
            while try !predicate() {
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw TerminalRuntimeConnectionError.timedOut }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }

        func stop() {
            if let proxy, proxy.isRunning { proxy.terminate(); proxy.waitUntilExit() }
            connection?.close()
            if service.isRunning { service.terminate(); service.waitUntilExit() }
            if FileManager.default.fileExists(atPath: root.path) {
                do { try FileManager.default.removeItem(at: root) }
                catch { XCTFail("Could not remove owned compatibility fixture") }
            }
        }

        private static let proxyScript = #"""
require "socket"
require "json"
require "securerandom"
upstream_root, root, mode, limit = ARGV
server = UNIXServer.new(File.join(root, "runtime.sock"))
actions = []
begin
  downstream = server.accept
  upstream = UNIXSocket.new(File.join(upstream_root, "runtime.sock"))
  count = mode == "epoch" ? 2 : 1
  count.times do |index|
    line = downstream.gets or raise "Missing fixture request"
    request = JSON.parse(line)
    actions << request.fetch("action")
    upstream.write(line)
    response = JSON.parse(upstream.gets)
    case mode
    when "protocol" then response["protocolVersion"] = 999
    when "identity" then response["id"] = SecureRandom.uuid
    when "epoch" then response["serviceEpoch"] = SecureRandom.uuid if index == 1
    end
    frame = case mode
    when "malformed" then "{invalid-fixture-response}\n"
    when "oversized" then "x" * (Integer(limit) + 1) + "\n"
    else JSON.generate(response) + "\n"
    end
    downstream.write(frame)
  end
rescue Errno::EPIPE, Errno::ECONNRESET
  # The real Swift client intentionally closes rejected responses.
ensure
  temporary = File.join(root, "actions.pending")
  File.open(temporary, "w", 0600) { |file| file.write(JSON.generate(actions)) }
  File.rename(temporary, File.join(root, "actions.json"))
  downstream&.close
  upstream&.close
  server.close
end
"""#
    }
}
