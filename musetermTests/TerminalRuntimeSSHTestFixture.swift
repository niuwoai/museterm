import Darwin
import Foundation
import XCTest
@testable import museterm

/// Owned real OpenSSH fixture; its JSON control pipe contains metadata only.
@MainActor
final class TerminalRuntimeSSHTestFixture {
    struct Metadata: Decodable {
        let root: String
        let port: Int
        let user: String
    }

    let metadata: Metadata
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()

    init() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ruby")
        process.arguments = ["-r", "json", "-r", repository.appendingPathComponent("scripts/support/runtime_ssh_fixture.rb").path,
            "-e", Self.driver]
        process.environment = ["PATH": "/usr/bin:/bin"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        do {
            metadata = try JSONDecoder().decode(Metadata.self, from: Self.readLine(output.fileHandleForReading))
        } catch {
            try input.fileHandleForWriting.close()
            if process.isRunning { process.terminate(); process.waitUntilExit() }
            throw error
        }
    }

    func disconnect(reset: Bool = false) throws {
        try input.fileHandleForWriting.write(contentsOf: Data((reset ? "reset\n" : "drop\n").utf8))
        let acknowledgement = try JSONSerialization.jsonObject(with: Self.readLine(output.fileHandleForReading)) as? [String: Bool]
        XCTAssertEqual(acknowledgement?["dropped"], true)
    }

    func stop() throws {
        try input.fileHandleForWriting.write(contentsOf: Data("stop\n".utf8))
        let acknowledgement = try JSONSerialization.jsonObject(with: Self.readLine(output.fileHandleForReading)) as? [String: Bool]
        XCTAssertEqual(acknowledgement?["stopping"], true)
        try input.fileHandleForWriting.close()
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
        guard !process.isRunning else {
            process.terminate()
            throw TerminalRuntimeConnectionError.timedOut
        }
        process.waitUntilExit()
        let diagnostic = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .replacingOccurrences(of: metadata.root, with: "<fixture>")
        XCTAssertEqual(process.terminationStatus, 0, "Owned OpenSSH fixture did not cleanly stop: \(diagnostic.prefix(500))")
        XCTAssertFalse(FileManager.default.fileExists(atPath: metadata.root), "Ephemeral SSH keys must be removed")
        try output.fileHandleForReading.close()
        try errors.fileHandleForReading.close()
    }

    private static func readLine(_ handle: FileHandle) throws -> Data {
        var bytes = Data()
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while bytes.last != 10 {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw TerminalRuntimeConnectionError.timedOut }
            var fd = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&fd, 1, Int32(min(remaining * 1_000, 8_000))) > 0,
                  let byte = try handle.read(upToCount: 1), !byte.isEmpty else { throw TerminalRuntimeConnectionError.unavailable }
            bytes.append(byte)
            guard bytes.count <= 4_096 else { throw TerminalRuntimeConnectionError.frameTooLarge }
        }
        return bytes
    }

    private static let driver = #"""
STDOUT.sync = true
fixture = RuntimeSSHFixture.new(force_shell: true)
begin
  puts JSON.generate({root: fixture.root, port: fixture.port, user: Etc.getpwuid.name})
  STDIN.each_line do |line|
    if line.strip == "stop"
      puts JSON.generate({stopping: true})
      break
    end
    raise "Unknown fixture command" unless %w[drop reset].include?(line.strip)
    fixture.disconnect(reset: line.strip == "reset")
    puts JSON.generate({dropped: true})
  end
ensure
  fixture.stop
end
"""#
}
