#!/usr/bin/env ruby
require "json"
require "tmpdir"
require "fileutils"
require "securerandom"
require "digest"
require "time"
require_relative "support/runtime_probe_client"

def await_condition
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
  loop do
    value = yield
    return value if value
    raise "Restart verification timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    sleep 0.025
  end
end

def identity(info)
  {"sessionID" => info.fetch("id"), "generation" => info.fetch("generation"), "controlEpoch" => info.fetch("controlEpoch")}
end

def accepted(response)
  raise "Request failed: #{response['error']}" unless response["ok"]
  response
end

binary = File.expand_path(ARGV.fetch(0))
prefix = File.expand_path(ARGV.fetch(1, "/private/tmp/qterm-runtime-restart"))
root = Dir.mktmpdir("qrt-restart-", "/private/tmp")
File.chmod(0o700, root)
server = nil
client = nil
checks = []
failure = nil
begin
  server = Process.spawn(binary, "--root", root, in: File::NULL, out: File::NULL, err: File::NULL)
  await_condition { File.file?(File.join(root, "ui-capability")) }
  client = RuntimeProbeClient.new(root)
  features = accepted(client.request("list")).fetch("features")
  raise "Restart feature not advertised" unless features.include?("restart_exited_v1")
  checks << "restart_capability_advertised_without_breaking_protocol_3"
  launch = {"executable" => "/bin/sh", "arguments" => ["-c", "printf '__OLD_EXITED\\n'"],
            "environment" => {"PATH" => "/usr/bin:/bin"}, "directory" => root, "columns" => 80, "rows" => 24}
  original = accepted(client.request("create", {"launch" => launch})).fetch("session")
  original = await_condition do
    info = accepted(client.request("list")).fetch("sessions").find { |item| item["id"] == original["id"] }
    info unless info["running"]
  end
  previous = identity(original)
  counter = File.join(root, "starts")
  replacement_launch = launch.merge("executable" => "/usr/bin/ruby", "arguments" => ["-e",
    'File.open(ARGV.fetch(0), "a") { |file| file.write("x") }; STDOUT.sync = true; puts "__NEW_RUNNING"; sleep 60', counter])
  {"generation" => SecureRandom.uuid, "controlEpoch" => SecureRandom.uuid}.each do |key, value|
    response = client.request("restartExited", previous.merge(key => value, "launch" => replacement_launch))
    expected = key == "generation" ? "generation_changed" : "control_changed"
    raise "Stale identity accepted" unless response["error"] == expected
  end
  checks << "stale_generation_and_control_rejected"
  failed = client.request("restartExited", previous.merge("launch" => replacement_launch.merge("executable" => "/qterm-no-such-program")))
  raise "Invalid exec accepted" unless failed["error"] == "process_launch_failed"
  retained = accepted(client.request("list")).fetch("sessions").find { |item| item["id"] == original["id"] }
  raise "Failed launch destroyed recovery record" unless retained["generation"] == original["generation"] && retained["pid"] == original["pid"]
  checks << "failed_exec_retains_original_exited_identity"
  request_id = SecureRandom.uuid
  request = previous.merge("launch" => replacement_launch)
  replacement = accepted(client.request("restartExited", request, id: request_id)).fetch("session")
  raise "No new generation" unless replacement["id"] == original["id"] && replacement["pid"] != original["pid"] && replacement["generation"] != original["generation"]
  checks << "same_terminal_new_pid_and_generation"
  # Simulate a lost response: resend the identical operation from a new socket.
  client.close
  client = RuntimeProbeClient.new(root)
  replay = accepted(client.request("restartExited", request, id: request_id)).fetch("session")
  raise "Duplicate restart created another process" unless replay["generation"] == replacement["generation"] && replay["pid"] == replacement["pid"]
  await_condition { File.file?(counter) }
  raise "Restart command executed twice" unless File.read(counter) == "x"
  checks << "lost_ack_replay_uses_cached_result_without_second_exec"
  live_attempt = client.request("restartExited", identity(replacement).merge("launch" => replacement_launch))
  raise "Live process restarted" unless live_attempt["error"] == "invalid_request"
  stale_attempt = client.request("restartExited", request)
  raise "Old generation restarted replacement" unless stale_attempt["error"] == "generation_changed"
  checks << "live_process_and_late_old_generation_preserved"
  raise "Context leaked after failed/replaced launch" unless Dir.glob(File.join(root, "native-tools/native-agent-contexts/*.json")).length == 1
  checks << "only_new_native_status_bootstrap_remains"
  accepted(client.request("close", identity(replacement)))
  accepted(client.request("shutdownIfEmpty"))
  await_condition { Process.waitpid(server, Process::WNOHANG) }
  raise "Service failed" unless $?.success?
  server = nil
  checks << "explicit_close_and_empty_service_shutdown"
rescue => error
  failure = "#{error.class}: #{error.message}"
ensure
  client&.close
  if server
    begin
      cleanup = RuntimeProbeClient.new(root)
      accepted(cleanup.request("list")).fetch("sessions").each { |info| cleanup.request("close", identity(info)) }
      cleanup.request("shutdownIfEmpty")
      cleanup.close
      await_condition { Process.waitpid(server, Process::WNOHANG) }
    rescue => error
      warn "Owned fixture cleanup failed: #{error.class}"
      begin
        Process.kill("TERM", server)
        Process.waitpid(server)
      rescue Errno::ESRCH, Errno::ECHILD
        warn "Owned fixture process already gone"
      end
    end
  end
  FileUtils.remove_entry(root)
end
report = {"generatedAt" => Time.now.iso8601, "version" => "1.251.0-rc6", "build" => 321,
          "passed" => failure.nil?, "failure" => failure, "checks" => checks,
          "helperSHA256" => Digest::SHA256.file(binary).hexdigest,
          "scope" => "真实私有 Socket/PTY 重启契约，不代表 SSH 服务器或全部 GUI 验收"}
File.write(prefix + ".json", JSON.pretty_generate(report) + "\n")
File.write(prefix + ".md", (["# 已退出 PTY 重启验证", "", "通过：#{report['passed']}，检查：#{checks.length}", ""] + checks.map { |check| "- #{check}" } + ["", failure.to_s, "", report["scope"], ""]).join("\n"))
puts JSON.generate(report)
exit(failure ? 1 : 0)
