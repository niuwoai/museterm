#!/usr/bin/env ruby
require "json"
require "tmpdir"
require "fileutils"
require "digest"
require "time"
require_relative "support/runtime_probe_client"

def await_command_condition
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
  loop do
    value = yield
    return value if value
    raise "Command verification timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    sleep 0.01
  end
end

binary = File.expand_path(ARGV.fetch(0))
prefix = File.expand_path(ARGV.fetch(1))
root = Dir.mktmpdir("qrt-cmd-", "/private/tmp")
File.chmod(0o700, root)
server = nil
client = nil
checks = []
failure = nil
begin
  server = Process.spawn(binary, "--root", root, in: File::NULL, out: File::NULL, err: File::NULL)
  await_command_condition { File.file?(File.join(root, "ui-capability")) }
  client = RuntimeProbeClient.new(root)
  request = lambda do |action, fields = {}|
    response = client.request(action, fields)
    raise "Runtime request rejected: #{response['error']}" unless response["ok"]
    response
  end
  metadata = request.call("list")
  raise "Command feature missing" unless metadata.fetch("features").include?("command_lifecycle_v1")
  # More than the per-tick PTY read budget; the child can exit before the tail is drained.
  start = "\e]777;MuseTerm;start=6563686f2070726976617465\a"
  finish = "\e]777;MuseTerm;end=7\a"
  create = lambda do |body|
    request.call("create", {"launch" => {"executable" => "/usr/bin/ruby", "arguments" => ["-e", body],
      "directory" => root, "environment" => {"PATH" => "/usr/bin:/bin"}, "columns" => 80, "rows" => 24}}).fetch("session")
  end
  latest = lambda do |id|
    request.call("list").fetch("sessions").find { |item| item["id"] == id }
  end
  flood = create.call("STDOUT.sync = true; STDOUT.write(#{start.dump}); STDOUT.write('x' * 200_000); STDOUT.write(#{finish.dump})")
  completed = await_command_condition do
    info = latest.call(flood.fetch("id"))
    info if !info["running"] && info.fetch("commands", []).last&.fetch("state") == "failed"
  end
  raise "Final marker code lost behind flood" unless completed.fetch("commands").last["exitCode"] == 7
  checks << "final_marker_after_large_output_is_drained_before_unknown_process_completion"
  unknown = create.call("STDOUT.sync = true; STDOUT.write(#{start.dump}); exit 0")
  exited = await_command_condition do
    info = latest.call(unknown.fetch("id"))
    info if !info["running"] && info.fetch("commands", []).last&.fetch("state") == "completed_unknown_status"
  end
  raise "Child exit code invented command success" unless exited.fetch("commands").last["exitCode"].nil?
  checks << "process_exit_without_shell_end_remains_unknown_even_with_child_exit_zero"
  first_id = completed.fetch("commands").last.fetch("id")
  raise "Different generations reused command identity" if exited.fetch("commands").last.fetch("id") == first_id
  checks << "separate_pty_generations_keep_distinct_command_identity"
  events = request.call("readEvents", {"eventAfter" => {"appEpoch" => metadata.fetch("serviceEpoch"), "sequence" => 0}})
  raise "Command plaintext leaked into metadata events" if JSON.generate(events).include?("private")
  checks << "command_events_do_not_contain_command_text"
  [completed, exited].each do |info|
    request.call("close", {"sessionID" => info.fetch("id"), "generation" => info.fetch("generation"), "controlEpoch" => info.fetch("controlEpoch")})
  end
  request.call("shutdownIfEmpty")
  await_command_condition { Process.waitpid(server, Process::WNOHANG) }
  raise "Service did not exit cleanly" unless $?.success?
  server = nil
rescue => error
  failure = "#{error.class}: #{error.message}"
ensure
  client&.close
  if server
    begin
      Process.kill("TERM", server)
      Process.waitpid(server)
    rescue Errno::ESRCH, Errno::ECHILD
      warn "Owned command fixture already exited"
    end
  end
  FileUtils.remove_entry(root)
end
report = {"generatedAt" => Time.now.iso8601, "version" => metadata && metadata["version"],
  "passed" => failure.nil?, "failure" => failure, "checks" => checks,
  "helperSHA256" => Digest::SHA256.file(binary).hexdigest,
  "scope" => "真实 PTY 退出与尾部标记排空；不包含 GUI 或远端 SSH"}
File.write(prefix + ".json", JSON.pretty_generate(report) + "\n")
File.write(prefix + ".md", (["# 后台命令退出边界", "", "通过：#{report['passed']}，检查：#{checks.length}", ""] +
  checks.map { |check| "- #{check}" } + ["", failure.to_s, "", report["scope"], ""]).join("\n"))
puts JSON.generate(report)
exit(failure ? 1 : 0)
