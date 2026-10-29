#!/usr/bin/env ruby
require "json"
require "tmpdir"
require "fileutils"
require "securerandom"
require "digest"
require "time"
require_relative "support/runtime_probe_client"

def await_agent_condition
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
  loop do
    value = yield
    return value if value
    raise "Agent tool verification timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    sleep 0.025
  end
end

def checked(response)
  raise "Request rejected: #{response['error']}" unless response["ok"]
  response
end

def target(info)
  {"sessionID" => info.fetch("id"), "generation" => info.fetch("generation")}
end

binary = File.expand_path(ARGV.fetch(0))
prefix = File.expand_path(ARGV.fetch(1, "/private/tmp/museterm-agent-tools"))
root = Dir.mktmpdir("qrt-agent-tools-", "/private/tmp")
File.chmod(0o700, root)
server = nil
client = nil
checks = []
failure = nil
begin
  server = Process.spawn(binary, "--root", root, in: File::NULL, out: File::NULL, err: File::NULL)
  await_agent_condition { File.file?(File.join(root, "ui-capability")) }
  client = RuntimeProbeClient.new(root)
  initial = checked(client.request("list"))
  raise "Missing feature" unless initial.fetch("features").include?("agent_tools_v1")
  checks << "agent_tools_feature_negotiated_on_protocol_3"
  launch = {"executable" => "/bin/sh", "arguments" => ["-c", "sleep 60"], "directory" => root,
            "environment" => {"PATH" => "/usr/bin:/bin"}, "columns" => 80, "rows" => 24}
  session = checked(client.request("create", {"launch" => launch})).fetch("session")
  other = checked(client.request("create", {"launch" => launch})).fetch("session")
  bound = checked(client.request("bindAgent", target(session).merge("agentKind" => "willdeep")))
  grant = bound.fetch("agentGrant")
  raise "Binding granted input" unless bound.fetch("session")["controlOwner"].nil?
  raise "Status secret grants input API" unless client.request("list", {"capability" => grant.fetch("token")})["error"] == "invalid_capability"
  checks << "status_grant_never_authorizes_ui_or_input_socket"
  report = grant.merge("sequence" => 1, "activity" => "blocked", "blockReason" => "approval")
  wrong = client.request("reportAgent", target(other).merge("agentReport" => report))
  raise "Cross-terminal report accepted" unless wrong["error"] == "invalidCapability"
  stale = client.request("reportAgent", target(session).merge("generation" => SecureRandom.uuid, "agentReport" => report))
  raise "Stale process generation accepted" unless stale["error"] == "generation_changed"
  checks << "status_report_scoped_to_terminal_and_process_generation"
  blocked = checked(client.request("reportAgent", target(session).merge("agentReport" => report)))
  raise "Approval not unique" unless blocked.fetch("attention").length == 1 && blocked["attention"][0]["kind"] == "approval"
  checks << "binding_report_and_inbox_use_same_backend_monitor"
  client.close
  client = RuntimeProbeClient.new(root)
  fresh = checked(client.request("getAgentState", target(session)))
  raise "Reattachment lost report" unless fresh.dig("session", "agent", "instanceID") == grant["instanceID"] && fresh.fetch("attention").length == 1
  raise "Status read leaked grant" if fresh.key?("agentGrant")
  checks << "disconnect_reconnect_queries_fresh_state_without_grant_leak"
  duplicate = client.request("reportAgent", target(session).merge("agentReport" => report))
  raise "Repeated sequence accepted" unless duplicate["error"] == "staleSequence"
  report = grant.merge("sequence" => 2, "activity" => "working")
  checked(client.request("reportAgent", target(session).merge("agentReport" => report)))
  report = grant.merge("sequence" => 3, "activity" => "idle", "result" => "completed")
  completed = checked(client.request("reportAgent", target(session).merge("agentReport" => report)))
  raise "Completion duplicated" unless completed.fetch("attention").length == 1 && completed["attention"][0]["kind"] == "completed"
  checks << "repeated_sequence_rejected_and_completion_unique"
  replacement = checked(client.request("bindAgent", target(session).merge("agentKind" => "codex")))
  report["sequence"] = 4
  raise "Replaced binding still authorized" if client.request("reportAgent", target(session).merge("agentReport" => report))["ok"]
  events = checked(client.request("readEvents", {"eventAfter" => {"appEpoch" => initial.fetch("serviceEpoch"), "sequence" => 0}}))
  raise "Secret leaked into events" if JSON.generate(events).include?(grant.fetch("token")) || JSON.generate(events).include?(replacement.fetch("agentGrant").fetch("token"))
  checks << "replacement_invalidates_old_grant_and_events_are_redacted"
  checked(client.request("list")).fetch("sessions").each do |info|
    checked(client.request("close", target(info).merge("controlEpoch" => info.fetch("controlEpoch"))))
  end
  checked(client.request("shutdownIfEmpty"))
  await_agent_condition { Process.waitpid(server, Process::WNOHANG) }
  raise "Server failed" unless $?.success?
  server = nil
rescue => error
  failure = "#{error.class}: #{error.message}"
ensure
  client&.close
  if server
    begin
      cleanup = RuntimeProbeClient.new(root)
      checked(cleanup.request("list")).fetch("sessions").each do |info|
        checked(cleanup.request("close", target(info).merge("controlEpoch" => info.fetch("controlEpoch"))))
      end
      checked(cleanup.request("shutdownIfEmpty"))
      cleanup.close
      await_agent_condition { Process.waitpid(server, Process::WNOHANG) }
    rescue => error
      warn "Owned Agent fixture cleanup failed: #{error.class}"
      begin
        Process.kill("TERM", server)
        Process.waitpid(server)
      rescue Errno::ESRCH, Errno::ECHILD
        warn "Owned Agent fixture already exited"
      end
    end
  end
  FileUtils.remove_entry(root)
end
report = {"generatedAt" => Time.now.iso8601, "version" => "1.251.0-rc8", "build" => 323,
          "passed" => failure.nil?, "failure" => failure, "checks" => checks,
          "helperSHA256" => Digest::SHA256.file(binary).hexdigest,
          "scope" => "实际 Socket/PTY 通用 Agent 操作契约，不代表独立 CLI/MCP 事件等待已完成"}
File.write(prefix + ".json", JSON.pretty_generate(report) + "\n")
File.write(prefix + ".md", (["# 后台 Agent 工具路由验证", "", "通过：#{report['passed']}，检查：#{checks.length}", ""] + checks.map { |check| "- #{check}" } + ["", failure.to_s, "", report["scope"], ""]).join("\n"))
puts JSON.generate(report)
exit(failure ? 1 : 0)
