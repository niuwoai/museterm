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

    func testBackendBindingReportsWithoutUIAndKeepsPublicDateFormat() throws {
        let result = try runRuby(#"""
def send_request(**args)
  raise "UI bridge must not be used for this binding."
end
ensure_dirs
endpoint = File.join(ROOT, "native-tools")
%w[requests responses].each { |name| FileUtils.mkdir_p(File.join(endpoint, name), mode: 0o700) }
File.chmod(0o700, endpoint)
worker = Thread.new do
  loop do
    path = Dir.glob(File.join(endpoint, "requests", "*.json")).first
    unless path
      sleep 0.01
      next
    end
    request = JSON.parse(File.read(path))
    response = {"id" => request["id"], "action" => request["action"], "ok" => true, "appName" => "QTerm",
      "agent" => {"updatedAt" => 0, "expiresAt" => 120, "activity" => request.dig("agentReport", "activity")}}
    File.open(File.join(endpoint, "responses", "#{request['id']}.json"), File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(JSON.generate(response)) }
    break
  end
end
path = store_agent_binding("11111111-1111-1111-1111-111111111111",
  {"instanceID" => "instance", "runID" => "run", "token" => "fixture-capability"}, endpoint)
response = report_agent_binding({"bindingFile" => path, "activity" => "working"})
worker.join
puts JSON.generate({"ok" => response["ok"], "activity" => response.dig("agent", "activity"),
  "updatedAt" => response.dig("agent", "updatedAt"), "app" => response["app"],
  "requests" => Dir.glob(File.join(endpoint, "requests", "*.json")).length,
  "responses" => Dir.glob(File.join(endpoint, "responses", "*.json")).length,
  "leaked" => JSON.generate(response).include?("fixture-capability")})
"""#)
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(result["activity"] as? String, "working")
        XCTAssertEqual(result["updatedAt"] as? String, "2001-01-01T00:00:00Z")
        XCTAssertEqual(result["app"] as? String, "QTerm")
        XCTAssertEqual(result["requests"] as? Int, 0)
        XCTAssertEqual(result["responses"] as? Int, 0)
        XCTAssertEqual(result["leaked"] as? Bool, false)
    }

    func testUnsafeBackendEndpointDoesNotFallBackToUI() throws {
        let result = try runRuby(#"""
def send_request(**args)
  raise "Must not fall back to UI authority."
end
ensure_dirs
endpoint = File.join(ROOT, "unsafe-endpoint")
FileUtils.mkdir_p(endpoint, mode: 0o755)
File.chmod(0o755, endpoint)
path = store_agent_binding("11111111-1111-1111-1111-111111111111",
  {"instanceID" => "instance", "runID" => "run", "token" => "fixture-capability"}, endpoint)
begin
  report_agent_binding({"bindingFile" => path, "activity" => "working"})
  puts JSON.generate({"rejected" => false})
rescue RuntimeError => error
  puts JSON.generate({"rejected" => error.message == "Unsafe status endpoint."})
end
"""#)
        XCTAssertEqual(result["rejected"] as? Bool, true)
    }

    func testBackendEventRoutingIgnoresDeadUIAndNormalizesNestedDates() throws {
        let result = try runRuby(#"""
def send_request(**args); raise "Must not use UI route."; end
ensure_dirs
endpoint = File.join(ROOT, "event-backend")
%w[requests responses].each { |name| FileUtils.mkdir_p(File.join(endpoint, name), mode: 0o700) }
File.chmod(0o700, endpoint)
ui_epoch = SecureRandom.uuid
service_epoch = SecureRandom.uuid
source = {"schemaVersion" => 1, "root" => endpoint, "cursor" => {"appEpoch" => service_epoch, "sequence" => 7}}
private_tool_request(File.join(ROOT, "runtime.json"), {"appEpoch" => ui_epoch, "pid" => 2147483647, "backend" => source})
legacy_selected = backend_runtime_source({"appEpoch" => ui_epoch, "sequence" => 0}).nil?
worker = Thread.new do
  2.times do
    path = nil
    until path
      path = Dir.glob(File.join(endpoint, "requests", "*.json")).first
      sleep 0.01 unless path
    end
    request = JSON.parse(File.read(path))
    File.delete(path)
    payload = if request["action"] == "read_session_events"
      {"eventBatch" => {"nextCursor" => source["cursor"], "events" => [{"occurredAt" => 0, "attention" => {"createdAt" => 120}}]}}
    else
      {"waitResult" => {"outcome" => "matched", "cursor" => source["cursor"], "agent" => {"updatedAt" => 0}}}
    end
    private_tool_request(File.join(endpoint, "responses", "#{request['id']}.json"),
      {"id" => request["id"], "action" => request["action"], "ok" => true}.merge(payload))
  end
end
events = agent_request("read_session_events", {})
waited = wait_tool({"spec" => {"condition" => "events", "after" => source["cursor"], "timeoutSeconds" => 1}})
worker.join
puts JSON.generate({"legacySelected" => legacy_selected, "epoch" => events.dig("eventBatch", "nextCursor", "appEpoch") == service_epoch,
  "occurredAt" => events.dig("eventBatch", "events", 0, "occurredAt"),
  "createdAt" => events.dig("eventBatch", "events", 0, "attention", "createdAt"),
  "outcome" => waited.dig("waitResult", "outcome"), "updatedAt" => waited.dig("waitResult", "agent", "updatedAt")})
"""#)
        XCTAssertEqual(result["legacySelected"] as? Bool, true)
        XCTAssertEqual(result["epoch"] as? Bool, true)
        XCTAssertEqual(result["occurredAt"] as? String, "2001-01-01T00:00:00Z")
        XCTAssertEqual(result["createdAt"] as? String, "2001-01-01T00:02:00Z")
        XCTAssertEqual(result["outcome"] as? String, "matched")
        XCTAssertEqual(result["updatedAt"] as? String, "2001-01-01T00:00:00Z")
    }

    func testBackendServiceRestartAndExitUseServiceMetadata() throws {
        let result = try runRuby(#"""
ensure_dirs
endpoint = File.join(ROOT, "service-metadata")
FileUtils.mkdir_p(endpoint, mode: 0o700)
epoch = SecureRandom.uuid
metadata = {"schemaVersion" => 1, "appEpoch" => epoch, "pid" => Process.pid, "cursor" => {"appEpoch" => epoch, "sequence" => 0}}
path = File.join(endpoint, "runtime.json")
private_tool_request(path, metadata)
restart = backend_wait_runtime_result(endpoint, "fixture", {"after" => {"appEpoch" => SecureRandom.uuid, "sequence" => 0}})
private_tool_request(path, metadata.merge("pid" => 2147483647))
exit_result = backend_wait_runtime_result(endpoint, "fixture", {"after" => metadata["cursor"]})
puts JSON.generate({"restart" => restart.dig("waitResult", "outcome"), "exit" => exit_result.dig("waitResult", "outcome")})
"""#)
        XCTAssertEqual(result["restart"] as? String, "appRestarted")
        XCTAssertEqual(result["exit"] as? String, "appExited")
    }

    func testDeclaredUnsafeEventEndpointNeverFallsBack() throws {
        let result = try runRuby(#"""
def send_request(**args); raise "Unexpected UI fallback."; end
ensure_dirs
endpoint = File.join(ROOT, "public-endpoint")
FileUtils.mkdir_p(endpoint, mode: 0o755)
File.chmod(0o755, endpoint)
epoch = SecureRandom.uuid
private_tool_request(File.join(ROOT, "runtime.json"), {"appEpoch" => SecureRandom.uuid,
  "backend" => {"schemaVersion" => 1, "root" => endpoint, "cursor" => {"appEpoch" => epoch, "sequence" => 0}}})
begin
  agent_request("read_session_events", {})
  puts JSON.generate({"rejected" => false})
rescue RuntimeError => error
  puts JSON.generate({"rejected" => error.message == "Unsafe backend event endpoint."})
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
