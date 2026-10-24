#!/usr/bin/env ruby
require "json"
require "tmpdir"
require "fileutils"
require "digest"
require "time"
require_relative "support/runtime_probe_client"
require_relative "support/runtime_ssh_fixture"

def await_ssh_condition
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 12
  loop do
    result = yield
    return result if result
    raise "Authenticated SSH verification timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    sleep 0.025
  end
end

def ssh_target(info)
  {"sessionID" => info.fetch("id"), "generation" => info.fetch("generation"), "controlEpoch" => info.fetch("controlEpoch")}
end

binary = File.expand_path(ARGV.fetch(0))
prefix = File.expand_path(ARGV.fetch(1, "/private/tmp/qterm-authenticated-ssh"))
root = Dir.mktmpdir("qrs-", "/private/tmp")
File.chmod(0700, root)
fixture = nil
server = nil
client = nil
checks = []
failure = nil
version = nil
begin
  fixture = RuntimeSSHFixture.new
  server = Process.spawn({"PATH" => "/usr/bin:/bin", "HOME" => root}, binary, "--root", root,
    in: File::NULL, out: File::NULL, err: File::NULL, unsetenv_others: true)
  await_ssh_condition { File.file?(File.join(root, "ui-capability")) }
  client = RuntimeProbeClient.new(root)
  call = lambda do |action, fields = {}|
    response = client.request(action, fields)
    raise "Backend rejected #{action}: #{response['error']}" unless response["ok"]
    response
  end
  version = call.call("hello").fetch("version")
  launch = {"executable" => "/usr/bin/ssh", "arguments" => fixture.arguments, "directory" => root,
    "environment" => {"PATH" => "/usr/bin:/bin", "HOME" => root, "TERM" => "xterm-256color", "LANG" => "C"},
    "columns" => 100, "rows" => 30}
  session = call.call("create", {"launch" => launch}).fetch("session")
  read = lambda { |info| call.call("read", ssh_target(info)).fetch("data", "").unpack1("m0").delete("\r") }
  await_ssh_condition { read.call(session).lines.map(&:strip).include?("__SSH_READY") }
  checks << "real_ssh_public_key_authentication_with_strict_pinned_host_key"
  original = session.slice("id", "pid", "generation")
  client.close
  client = RuntimeProbeClient.new(root)
  session = call.call("list").fetch("sessions").find { |s| s["id"] == original["id"] }
  raise "SSH client replaced after viewer detach" unless session.slice("id", "pid", "generation") == original && session["running"]
  checks << "viewer_disconnect_keeps_original_authenticated_ssh_process"
  execute = lambda do |info, marker|
    latest = call.call("list").fetch("sessions").find { |s| s["id"] == info["id"] }
    call.call("input", ssh_target(latest).merge("source" => "human", "inputSequence" => latest.fetch("nextInputSequence"),
      "data" => ["printf '\\n#{marker}\\n'\n"].pack("m0")))
    await_ssh_condition { read.call(latest).lines.map(&:strip).include?(marker) }
  end
  execute.call(session, "__SSH_INPUT_AFTER_ATTACH")
  checks << "reattached_ssh_accepts_real_remote_command"
  fixture.disconnect
  exited = await_ssh_condition do
    info = call.call("list").fetch("sessions").find { |s| s["id"] == session["id"] }
    info unless info["running"]
  end
  raise "Transport loss silently recreated a process" unless exited.slice("id", "pid", "generation") == original && exited["exitStatus"] == 255
  checks << "actual_network_transport_loss_preserves_exited_identity_without_implicit_replacement"
  restarted = call.call("restartExited", ssh_target(exited).merge("launch" => launch)).fetch("session")
  raise "Explicit reconnect did not create a new generation" unless restarted["id"] == exited["id"] && restarted["pid"] != exited["pid"] && restarted["generation"] != exited["generation"]
  await_ssh_condition { read.call(restarted).lines.map(&:strip).include?("__SSH_READY") }
  execute.call(restarted, "__SSH_RECONNECTED_OK")
  checks << "explicit_restart_reauthenticates_same_terminal_with_new_pid_and_generation"
  stale = client.request("restartExited", ssh_target(exited).merge("launch" => launch))
  raise "Stale reconnect accepted" unless stale["error"] == "generation_changed"
  checks << "late_old_generation_reconnect_cannot_replace_live_ssh"
  [["wrong_known_hosts", "client", "host_key"], ["known_hosts", "host", "public_key"]].each do |hosts, identity, kind|
    bad = call.call("create", {"launch" => launch.merge("arguments" => fixture.arguments(host_key: hosts, identity: identity))}).fetch("session")
    bad = await_ssh_condition do
      info = call.call("list").fetch("sessions").find { |s| s["id"] == bad["id"] }
      info unless info["running"]
    end
    output = read.call(bad)
    expected_error = kind == "host_key" ? "Host key verification failed" : "Permission denied (publickey)"
    raise "SSH failed without the expected authentication diagnostic" unless output.include?(expected_error)
    raise "Invalid SSH identity became an authenticated session" unless bad["exitStatus"] == 255 && !output.include?("__SSH_READY")
    call.call("close", ssh_target(bad))
    checks << "#{kind}_mismatch_fails_without_bypassing_authentication"
  end
  survivor = call.call("list").fetch("sessions").find { |s| s["id"] == restarted["id"] }
  raise "Negative cases replaced original SSH process" unless survivor && survivor["running"] &&
    survivor.slice("id", "pid", "generation") == restarted.slice("id", "pid", "generation")
  execute.call(restarted, "__SSH_ORIGINAL_SURVIVES_NEGATIVE_CASES")
  checks << "negative_authentication_cases_do_not_affect_original_reconnected_session"
  call.call("close", ssh_target(restarted))
  raise "Owned PTY remained" unless call.call("list").fetch("sessions").empty?
  call.call("shutdownIfEmpty")
  await_ssh_condition { Process.waitpid(server, Process::WNOHANG) }
  server = nil
  checks << "owned_ssh_pty_and_empty_backend_closed"
rescue => error
  failure = error.message
ensure
  if server
    begin
      client&.close
      cleanup = RuntimeProbeClient.new(root)
      cleanup.request("list").fetch("sessions").each { |s| cleanup.request("close", ssh_target(s)) }
      cleanup.request("shutdownIfEmpty")
      cleanup.close
      await_ssh_condition { Process.waitpid(server, Process::WNOHANG) }
    rescue => error
      failure ||= "Owned backend cleanup failed: #{error.class}"
      begin
        Process.kill("TERM", server)
      rescue Errno::ESRCH
        warn "Owned SSH verification helper already exited"
      end
      begin
        Process.waitpid(server)
      rescue Errno::ECHILD
        warn "Owned SSH verification helper already reaped"
      end
    end
  end
  client&.close
  begin
    fixture&.stop
  rescue => error
    failure ||= "Private SSH fixture cleanup failed: #{error.class}"
  ensure
    FileUtils.remove_entry(root)
  end
end
report = {"generatedAt" => Time.now.iso8601, "version" => version, "passed" => failure.nil?, "failure" => failure,
  "checks" => checks, "helperSHA256" => Digest::SHA256.file(binary).hexdigest, "ephemeralKeysRemoved" => fixture.nil? || !File.exist?(fixture.root),
  "scope" => "Actual authenticated loopback OpenSSH through real QTerm backend/PTYS with controlled network drop; not external remote server or GUI/Profile acceptance"}
File.write(prefix + ".json", JSON.pretty_generate(report) + "\n")
File.write(prefix + ".md", (["# 真实 SSH 认证、断连与显式重连", "", "通过：#{report['passed']}，检查：#{checks.length}", "", report["scope"], ""] + checks.map { |c| "- #{c}" } + ["", failure.to_s, ""]).join("\n"))
puts JSON.generate(report)
exit(failure ? 1 : 0)
