#!/usr/bin/env ruby
require "json"
require "tmpdir"
require "fileutils"
require "securerandom"
require "digest"
require "time"
require_relative "support/runtime_probe_client"
require_relative "support/runtime_wait_file_client"

def await_wait_condition(seconds = 10)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
  loop do
    value = yield
    return value if value
    raise "Runtime wait verification timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    sleep 0.01
  end
end

def checked_wait(response)
  raise "Request rejected: #{response['error']}" unless response["ok"]
  response
end

def wait_target(info)
  {"sessionID" => info.fetch("id"), "generation" => info.fetch("generation"), "controlEpoch" => info.fetch("controlEpoch")}
end

binary = File.expand_path(ARGV.fetch(0))
prefix = File.expand_path(ARGV.fetch(1, "/private/tmp/museterm-runtime-waits"))
root = Dir.mktmpdir("qrt-waits-", "/private/tmp")
File.chmod(0o700, root)
server = nil
socket = nil
checks = []
failure = nil
begin
  server = Process.spawn(binary, "--root", root, in: File::NULL, out: File::NULL, err: File::NULL)
  await_wait_condition { File.file?(File.join(root, "ui-capability")) }
  socket = RuntimeProbeClient.new(root)
  native = RuntimeWaitFileClient.new(root)
  listed = checked_wait(socket.request("list"))
  raise "Wait feature missing" unless listed.fetch("features").include?("event_wait_v1")
  launch = {"executable" => "/bin/sh", "arguments" => ["-c", 'stty sane -echo; printf "__WAIT_READY\n"; while IFS= read -r line; do eval "$line"; done'],
            "directory" => root, "environment" => {"PATH" => "/usr/bin:/bin"}, "columns" => 80, "rows" => 24}
  session = checked_wait(socket.request("create", {"launch" => launch})).fetch("session")
  await_wait_condition { checked_wait(socket.request("read", wait_target(session))).fetch("data", "").unpack1("m0").include?("__WAIT_READY") }
  grant = checked_wait(socket.request("bindAgent", wait_target(session).merge("agentKind" => "willdeep"))).fetch("agentGrant")
  sequence = 0
  report = lambda do |activity, reason = nil|
    sequence += 1
    body = grant.merge("sequence" => sequence, "activity" => activity)
    body["blockReason"] = reason if reason
    checked_wait(socket.request("reportAgent", wait_target(session).merge("agentReport" => body)))
  end
  report.call("working")
  cursor = lambda { checked_wait(native.request("read_session_events")).fetch("eventBatch").fetch("nextCursor") }
  raise "UI-independent event epoch mismatch" unless cursor.call["appEpoch"] == listed["serviceEpoch"]
  checks << "service_epoch_and_readonly_native_baseline"
  agent_spec = lambda do |activity, after = cursor.call|
    {"condition" => "agentState", "after" => after, "tabID" => session.fetch("id"),
     "instanceID" => grant.fetch("instanceID"), "runID" => grant.fetch("runID"), "activity" => activity, "timeoutSeconds" => 5}
  end
  owner = SecureRandom.uuid
  first = native.send("wait_session", {"controlID" => owner, "waitSpec" => agent_spec.call("blocked")})
  second = native.send("wait_session", {"controlID" => SecureRandom.uuid, "waitSpec" => agent_spec.call("blocked")})
  [first, second].each { |id| native.consumed(id) }
  report.call("blocked", "approval")
  [first, second].each do |id|
    result = checked_wait(native.receive(id)).fetch("waitResult")
    raise "Independent waiter did not match original Agent" unless result["outcome"] == "matched" && result.dig("agent", "instanceID") == grant["instanceID"]
  end
  checks << "independent_waiters_share_original_agent_without_consuming_each_other"
  report.call("working")
  attention_spec = {"condition" => "attention", "after" => cursor.call, "tabID" => session.fetch("id"), "timeoutSeconds" => 5}
  attention_wait = native.send("wait_session", {"controlID" => SecureRandom.uuid, "waitSpec" => attention_spec})
  native.consumed(attention_wait)
  fresh = checked_wait(native.request("get_agent_state", {"tab" => session.fetch("id")}))
  raise "Wait blocked fresh status query" unless fresh.dig("agent", "activity") == "working"
  report.call("blocked", "question")
  attention_result = checked_wait(native.receive(attention_wait)).fetch("waitResult")
  raise "New question did not match" unless attention_result["outcome"] == "matched" && attention_result.dig("attention", "kind") == "question"
  checks << "pending_attention_wait_does_not_block_queries_or_reports"
  report.call("working")
  cancelled = native.send("wait_session", {"controlID" => owner, "waitSpec" => agent_spec.call("idle")})
  native.consumed(cancelled)
  checked_wait(native.request("cancel_wait", {"controlID" => SecureRandom.uuid, "waitID" => cancelled}))
  raise "Wrong owner cancelled wait" if native.ready?(cancelled)
  checked_wait(native.request("cancel_wait", {"controlID" => owner, "waitID" => cancelled}))
  raise "Owner cancellation failed" unless checked_wait(native.receive(cancelled)).dig("waitResult", "outcome") == "cancelled"
  early = SecureRandom.uuid
  checked_wait(native.request("cancel_wait", {"controlID" => owner, "waitID" => early}))
  native.send("wait_session", {"controlID" => owner, "waitSpec" => agent_spec.call("idle")}, id: early)
  raise "Early cancellation lost" unless checked_wait(native.receive(early)).dig("waitResult", "outcome") == "cancelled"
  checks << "owner_scoped_and_early_cancellation"
  current = checked_wait(socket.request("list")).fetch("sessions").find { |info| info["id"] == session["id"] }
  output_spec = {"condition" => "outputChanged", "after" => cursor.call, "tabID" => session.fetch("id"), "revision" => current.fetch("outputRevision"), "timeoutSeconds" => 5}
  output_wait = native.send("wait_session", {"controlID" => owner, "waitSpec" => output_spec})
  native.consumed(output_wait)
  checked_wait(socket.request("input", wait_target(current).merge("source" => "human", "inputSequence" => current.fetch("nextInputSequence"), "data" => ["printf '__WAIT_INPUT_OK\\n'\n"].pack("m0"))))
  output_result = checked_wait(native.receive(output_wait)).fetch("waitResult")
  raise "Output wait failed" unless output_result["outcome"] == "matched" && output_result["revision"] > current["outputRevision"]
  raise "Wait acquired input lease" unless checked_wait(socket.request("list")).fetch("sessions")[0]["controlOwner"].nil?
  checks << "real_pty_output_revision_wait_and_input_continue_without_lease"
  [[agent_spec.call("idle").merge("timeoutSeconds" => 0), "timeout"],
   [agent_spec.call("idle").merge("after" => {"appEpoch" => SecureRandom.uuid, "sequence" => 0}), "appRestarted"],
   [agent_spec.call("idle").merge("after" => cursor.call.merge("sequence" => 9_000_000)), "futureCursor"]].each do |spec, outcome|
    result = checked_wait(native.request("wait_session", {"controlID" => owner, "waitSpec" => spec}))
    raise "Incorrect non-match outcome" unless result.dig("waitResult", "outcome") == outcome
  end
  checks << "timeout_and_wrong_epoch_future_cursor_are_explicit"
  bounded_owner = SecureRandom.uuid
  spec = {"condition" => "events", "after" => cursor.call, "timeoutSeconds" => 60}
  waiting = 16.times.map { native.send("wait_session", {"controlID" => bounded_owner, "waitSpec" => spec}) }
  waiting.each { |id| native.consumed(id) }
  overflow = native.request("wait_session", {"controlID" => bounded_owner, "waitSpec" => spec})
  raise "Owner waiter capacity exceeded" unless overflow["error"] == "capacityExceeded"
  checked_wait(native.request("cancel_all_waits", {"controlID" => bounded_owner}))
  waiting.each { |id| raise "Cancel all failed" unless checked_wait(native.receive(id)).dig("waitResult", "outcome") == "cancelled" }
  checks << "per_owner_waiter_limit_and_bounded_cancel_all"
  original_cursor = cursor.call
  800.times { |index| index.even? ? report.call("blocked", "approval") : report.call("working") }
  expired = native.request("read_session_events", {"eventCursor" => original_cursor})
  raise "Expired event cursor accepted" unless expired["error"] == "cursor_expired"
  expired_wait = checked_wait(native.request("wait_session", {"controlID" => owner, "waitSpec" => {"condition" => "events", "after" => original_cursor, "timeoutSeconds" => 0}}))
  raise "Expired wait cursor matched" unless expired_wait.dig("waitResult", "outcome") == "cursorExpired"
  checks << "bounded_event_journal_reports_cursor_expiry_for_reads_and_waits"
  replaced_wait = native.send("wait_session", {"controlID" => owner, "waitSpec" => agent_spec.call("idle")})
  native.consumed(replaced_wait)
  checked_wait(socket.request("bindAgent", wait_target(session).merge("agentKind" => "codex")))
  raise "Replaced Agent falsely matched" unless checked_wait(native.receive(replaced_wait)).dig("waitResult", "outcome") == "targetReplaced"
  missing = checked_wait(native.request("wait_session", {"controlID" => owner, "waitSpec" => {"condition" => "commandFinished", "after" => cursor.call, "tabID" => session["id"], "commandID" => SecureRandom.uuid}}))
  raise "Unknown command pretended complete" unless missing.dig("waitResult", "outcome") == "targetReplaced"
  checks << "agent_replacement_and_unknown_command_are_explicit"
  raise "Command lifecycle feature missing" unless listed.fetch("features").include?("command_lifecycle_v1")
  input_line = lambda do |line|
    info = checked_wait(socket.request("list")).fetch("sessions").find { |item| item["id"] == session["id"] }
    checked_wait(socket.request("input", wait_target(info).merge("source" => "human", "inputSequence" => info.fetch("nextInputSequence"), "data" => [line + "\n"].pack("m0"))))
  end
  input_line.call(%q{printf '\033]777;MuseTerm;start=6563686f20736563726574\007'})
  command = await_wait_condition do
    checked_wait(socket.request("list")).fetch("sessions")[0].fetch("commands").find { |item| item["state"] == "running" }
  end
  command_spec = {"condition" => "commandFinished", "after" => cursor.call, "tabID" => session["id"], "commandID" => command.fetch("id"), "timeoutSeconds" => 5}
  command_wait = native.send("wait_session", {"controlID" => owner, "waitSpec" => command_spec})
  native.consumed(command_wait)
  socket.close
  socket = nil
  sleep 0.3
  raise "Absent UI falsely finished command" if native.ready?(command_wait)
  socket = RuntimeProbeClient.new(root)
  input_line.call(%q{printf '\033]777;MuseTerm;end=7\007'})
  completed = checked_wait(native.receive(command_wait)).fetch("waitResult")
  raise "Original command failure lost" unless completed["outcome"] == "matched" && completed["commandID"] == command["id"] && completed["commandState"] == "failed"
  command_events = checked_wait(native.request("read_session_events", {"eventCursor" => command_spec["after"]})).fetch("eventBatch").fetch("events")
  raise "Command text leaked to event journal" if JSON.generate(command_events).include?("secret")
  raise "Completion event identity mismatch" unless command_events.any? { |event| event["kind"] == "commandFinished" && event["commandID"] == command["id"] && event["commandState"] == "failed" }
  checks << "real_shell_command_wait_survives_absent_clients_and_matches_exact_failure"
  close_wait = native.send("wait_session", {"controlID" => owner, "waitSpec" => {"condition" => "outputChanged", "after" => cursor.call, "tabID" => session["id"], "revision" => 9_000_000, "timeoutSeconds" => 5}})
  native.consumed(close_wait)
  checked_wait(socket.request("close", wait_target(session)))
  raise "Closed terminal wait not completed" unless checked_wait(native.receive(close_wait)).dig("waitResult", "outcome") == "targetClosed"
  exit_wait = native.send("wait_session", {"controlID" => owner, "waitSpec" => {"condition" => "events", "after" => cursor.call, "timeoutSeconds" => 5}})
  native.consumed(exit_wait)
  checked_wait(socket.request("shutdownIfEmpty"))
  raise "Service exit dropped pending wait" unless checked_wait(native.receive(exit_wait)).dig("waitResult", "outcome") == "appExited"
  await_wait_condition { Process.waitpid(server, Process::WNOHANG) }
  raise "Service exit failed" unless $?.success?
  server = nil
  checks << "target_close_and_graceful_service_exit_publish_final_outcomes"
rescue => error
  failure = "#{error.class}: #{error.message}"
ensure
  socket&.close
  if server
    begin
      cleanup = RuntimeProbeClient.new(root)
      checked_wait(cleanup.request("list")).fetch("sessions").each { |info| checked_wait(cleanup.request("close", wait_target(info))) }
      cleanup.request("shutdownIfEmpty")
      cleanup.close
      await_wait_condition { Process.waitpid(server, Process::WNOHANG) }
    rescue => error
      warn "Owned wait fixture cleanup failed: #{error.class}"
      begin
        Process.kill("TERM", server); Process.waitpid(server)
      rescue Errno::ESRCH, Errno::ECHILD
        warn "Owned wait fixture already gone"
      end
    end
  end
  FileUtils.remove_entry(root)
end
result = {"generatedAt" => Time.now.iso8601, "version" => listed && listed["version"],
          "passed" => failure.nil?, "failure" => failure, "checks" => checks, "helperSHA256" => Digest::SHA256.file(binary).hexdigest,
          "scope" => "真实后台只读文件端点、PTY 命令生命周期和客户端离线等待；通用生成 CLI/MCP 另由应用测试覆盖"}
File.write(prefix + ".json", JSON.pretty_generate(result) + "\n")
File.write(prefix + ".md", (["# 后台事件与有界等待验证", "", "通过：#{result['passed']}，检查：#{checks.length}", ""] + checks.map { |check| "- #{check}" } + ["", failure.to_s, "", result["scope"], ""]).join("\n"))
puts JSON.generate(result)
exit(failure ? 1 : 0)
