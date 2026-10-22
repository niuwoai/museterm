import XCTest
@testable import museterm

@MainActor
final class TerminalAgentCLITests: XCTestCase {
    private func runRuby(_ body: String) throws -> [String: Any] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qterm-agent-cli-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let definitions = try XCTUnwrap(MuseTermCLIInstaller.script.components(separatedBy: "\ncommand = ARGV.shift").first)
        let script = root.appendingPathComponent("fixture.rb")
        try (definitions + "\n" + body).write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ruby")
        process.arguments = [script.path]
        process.environment = ["HOME": root.path, "PATH": "/usr/bin:/bin"]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let error = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: error, as: UTF8.self))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testCLIBindingHidesSecretAndReportsMonotonicSequences() throws {
        let result = try runRuby(#"""
def send_request(**args)
  if args[:action] == "bind_agent"
    {"ok" => true, "agentGrant" => {"instanceID" => "instance", "runID" => "run", "token" => "fixture-capability"}}
  else
    {"ok" => true, "sequence" => args.fetch(:agent_report).fetch("sequence")}
  end
end
ensure_dirs
bound = agent_request("bind_agent", {"tab" => "11111111-1111-1111-1111-111111111111", "kind" => "codex"})
path = bound.fetch("bindingFile")
first = agent_request("report_agent_state", {"bindingFile" => path, "activity" => "working"})
second = agent_request("report_agent_state", {"bindingFile" => path, "activity" => "blocked", "blockReason" => "question"})
puts JSON.generate({"leaked" => JSON.generate(bound).include?("fixture-capability"), "mode" => File.stat(path).mode & 0o777,
  "directoryMode" => File.stat(File.dirname(path)).mode & 0o777, "sequences" => [first["sequence"], second["sequence"]]})
"""#)
        XCTAssertEqual(result["leaked"] as? Bool, false)
        XCTAssertEqual(result["mode"] as? Int, 0o600)
        XCTAssertEqual(result["directoryMode"] as? Int, 0o700)
        XCTAssertEqual(result["sequences"] as? [Int], [1, 2])
    }

    func testMCPUsesTheSameSafeBindingAndStatusHandlers() throws {
        let result = try runRuby(#"""
def send_request(**args)
  {"ok" => true, "agentGrant" => {"instanceID" => "instance", "runID" => "run", "token" => "fixture-capability"}}
end
ensure_dirs
response = call_tool("bind_agent", {"tab" => "11111111-1111-1111-1111-111111111111", "kind" => "claude"})
puts JSON.generate({"leaked" => JSON.generate(response).include?("fixture-capability"),
  "tools" => mcp_tools.map { |tool| tool["name"] }, "text" => response["content"][0]["text"]})
"""#)
        XCTAssertEqual(result["leaked"] as? Bool, false)
        XCTAssertTrue((result["text"] as? String)?.contains("bindingFile") == true)
        let tools = try XCTUnwrap(result["tools"] as? [String])
        for name in ["bind_agent", "report_agent_state", "get_agent_state", "read_session_events", "takeover_tab"] {
            XCTAssertTrue(tools.contains(name))
        }
    }

    func testNewBindingDoesNotOverwriteOldHooksFile() throws {
        let result = try runRuby(#"""
ensure_dirs
grant = {"instanceID" => "instance", "runID" => "run", "token" => "fixture-capability"}
one = store_agent_binding("11111111-1111-1111-1111-111111111111", grant)
two = store_agent_binding("11111111-1111-1111-1111-111111111111", grant.merge("runID" => "replacement"))
puts JSON.generate({"different" => one != two, "oldRun" => JSON.parse(File.read(one))["runID"]})
"""#)
        XCTAssertEqual(result["different"] as? Bool, true)
        XCTAssertEqual(result["oldRun"] as? String, "run")
    }

    func testReportRejectsUnsafeBindingFilePermissions() throws {
        let result = try runRuby(#"""
ensure_dirs
path = store_agent_binding("11111111-1111-1111-1111-111111111111", {"instanceID" => "instance", "runID" => "run", "token" => "fixture-capability"})
File.chmod(0o644, path)
begin
  report_agent_binding({"bindingFile" => path, "activity" => "working"})
  puts JSON.generate({"rejected" => false})
rescue RuntimeError => error
  puts JSON.generate({"rejected" => error.message == "Unsafe status binding permissions."})
end
"""#)
        XCTAssertEqual(result["rejected"] as? Bool, true)
    }

    func testCLIParsesEventsCursorAndEnforcesExplicitUUID() throws {
        let result = try runRuby(#"""
def send_request(**args)
  {"ok" => true, "cursor" => args[:event_cursor], "limit" => args[:event_limit]}
end
command_agent(["events", "--after", '{"appEpoch":"fixture","sequence":7}', "--limit", "2"])
"""#)
        XCTAssertEqual((result["cursor"] as? [String: Any])?["sequence"] as? Int, 7)
        XCTAssertEqual(result["limit"] as? Int, 2)
    }

    func testWaitRuntimeDetectsRestartAndExitedProcessWithoutReadingTerminalHistory() throws {
        let result = try runRuby(#"""
ensure_dirs
epoch = SecureRandom.uuid
cursor = {"appEpoch" => epoch, "sequence" => 1}
path = File.join(ROOT, "runtime.json")
File.write(path, JSON.generate({"appEpoch" => epoch, "pid" => Process.pid, "cursor" => cursor}))
restart = wait_runtime_result("fixture", {"after" => {"appEpoch" => SecureRandom.uuid}})
File.write(path, JSON.generate({"appEpoch" => epoch, "pid" => 2147483647, "cursor" => cursor}))
exited = wait_runtime_result("fixture", {"after" => {"appEpoch" => epoch}})
puts JSON.generate({"restart" => restart["waitResult"]["outcome"], "exit" => exited["waitResult"]["outcome"]})
"""#)
        XCTAssertEqual(result["restart"] as? String, "appRestarted")
        XCTAssertEqual(result["exit"] as? String, "appExited")
    }
}
