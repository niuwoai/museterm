#!/usr/bin/env ruby
require "socket"
require "json"
require "tmpdir"
require "fileutils"
require "securerandom"
require "base64"
require "time"
require "digest"

require_relative "support/runtime_probe_client"

class RuntimeProbeNativeClient
  def initialize(context)
    @context = context
  end

  def request(action, fields = {})
    id = SecureRandom.uuid
    request = {"id" => id, "action" => action, "tab" => @context.fetch("tabID")}.merge(fields)
    root = @context.fetch("root")
    temporary = File.join(root, "requests", id + ".pending")
    File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(JSON.generate(request)) }
    File.rename(temporary, File.join(root, "requests", id + ".json"))
    path = File.join(root, "responses", id + ".json")
    wait_for { File.file?(path) }
    raise "Native response permissions" unless File.stat(path).mode & 0o777 == 0o600
    response = JSON.parse(File.read(path))
    File.delete(path)
    raise "Native response identity" unless response["id"] == id
    response
  end
end

def ensure_ok(response)
  raise "Runtime request rejected: #{response['error']}" unless response["ok"]
  response
end

def target(info)
  {"sessionID" => info.fetch("id"), "generation" => info.fetch("generation"),
   "controlEpoch" => info.fetch("controlEpoch"), "inputSequence" => info.fetch("nextInputSequence")}
end

def wait_for(seconds = 10)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
  loop do
    value = yield
    return value if value
    raise "Probe condition timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    sleep 0.05
  end
end

binary = File.expand_path(ARGV.fetch(0))
prefix = File.expand_path(ARGV.fetch(1, "/private/tmp/qterm-runtime-probe"))
root = Dir.mktmpdir("qrt-", "/private/tmp")
File.chmod(0o700, root)
checks = []
session = nil
client = nil
server = nil
passed = false
failure = nil
begin
  log = File.open(File.join(root, "runtime.log"), File::WRONLY | File::CREAT | File::EXCL, 0o600)
  server = Process.spawn(binary, "--root", root, in: File::NULL, out: log, err: log)
  log.close
  wait_for { File.socket?(File.join(root, "runtime.sock")) && File.file?(File.join(root, "ui-capability")) }
  raise "Socket permissions" unless File.stat(File.join(root, "runtime.sock")).mode & 0o777 == 0o600
  checks << "private_socket_and_capability"
  before_capability = File.read(File.join(root, "ui-capability"))
  duplicate = Process.spawn(binary, "--root", root, in: File::NULL, out: File::NULL, err: File::NULL)
  wait_for { Process.waitpid(duplicate, Process::WNOHANG) }
  raise "Second server accepted live root" if $?.success?
  raise "Second server changed capability" unless File.read(File.join(root, "ui-capability")) == before_capability
  checks << "single_owner_without_killing_live_server"

  malformed = UNIXSocket.new(File.join(root, "runtime.sock"))
  malformed.write("{invalid-probe-frame-private-marker}\n")
  raise "Malformed client not disconnected" unless IO.select([malformed], nil, nil, 5) && malformed.read(1).nil?
  malformed.close
  diagnostics_client = RuntimeProbeClient.new(root)
  diagnostics = ensure_ok(diagnostics_client.request("diagnostics")).fetch("disconnects")
  raise "Missing malformed-frame diagnostic" unless diagnostics.any? { |item| item["reason"] == "invalid_frame" }
  allowed_diagnostic_keys = %w[reason lastAction subscribed queuedBytes idleSeconds]
  raise "Diagnostic contains request data" unless diagnostics.all? { |item| (item.keys - allowed_diagnostic_keys).empty? } &&
    !JSON.generate(diagnostics).include?("private-marker")
  raise "Diagnostics not capability protected" unless diagnostics_client.request("diagnostics", {"capability" => "invalid"})["error"] == "invalid_capability"
  40.times do
    invalid = UNIXSocket.new(File.join(root, "runtime.sock"))
    invalid.write("not-json-private-marker\n")
    raise "Malformed flood not bounded" unless IO.select([invalid], nil, nil, 2) && invalid.read(1).nil?
    invalid.close
  end
  bounded = ensure_ok(diagnostics_client.request("diagnostics")).fetch("disconnects")
  raise "Disconnect history not bounded" unless bounded.length == 32 && bounded.all? { |item| item["reason"] == "invalid_frame" }
  diagnostics_client.close
  checks << "bounded_private_disconnect_diagnostics_without_request_payload"

  # A separate frontend process creates and writes the terminal, then exits.
  pipe_read, pipe_write = IO.pipe
  frontend = fork do
    pipe_read.close
    begin
      connection = RuntimeProbeClient.new(root)
      launch = {"executable" => "/bin/sh", "arguments" => ["-i"], "directory" => root,
        "environment" => {"PATH" => "/usr/bin:/bin", "HOME" => root, "TERM" => "xterm-256color"},
        "columns" => 80, "rows" => 24}
      info = ensure_ok(connection.request("create", {"sessionID" => SecureRandom.uuid, "launch" => launch})).fetch("session")
      command = "stty -echo; printf '__PID:%s\\n' \"$$\"; i=0; while [ \"$i\" -lt 12 ]; do printf '__TICK:%s\\n' \"$i\"; i=$((i+1)); sleep 0.1; done; read value; printf '__INPUT:%s\\n' \"$value\"\n"
      info = ensure_ok(connection.request("input", target(info).merge("source" => "human", "data" => Base64.strict_encode64(command)))).fetch("session")
      pipe_write.write(JSON.generate(info))
      connection.close
      exit! 0
    rescue StandardError
      exit! 1
    end
  end
  pipe_write.close
  encoded_session = pipe_read.read
  pipe_read.close
  Process.waitpid(frontend)
  raise "Creating frontend failed" unless $?.success?
  session = JSON.parse(encoded_session)
  client = RuntimeProbeClient.new(root)
  hello = ensure_ok(client.request("hello"))
  raise "Version observability missing" unless hello["version"] && hello["serviceEpoch"]
  raise "State-only capability allowed control" unless client.request("list", {"capability" => "status-only"})["error"] == "invalid_capability"
  raise "Wrong protocol accepted" unless client.request("hello", {"protocolVersion" => 999})["error"] == "incompatible_protocol"
  checks << "protocol_version_and_distinct_capability"
  raise "Live service accepted shutdown" unless client.request("shutdownIfEmpty")["error"] == "control_owned"
  rejected_launch = {"executable" => "/bin/sh", "arguments" => Array.new(257, ""), "directory" => root,
    "environment" => {"PATH" => "/usr/bin:/bin"}, "columns" => 80, "rows" => 24}
  raise "Unbounded argument count accepted" unless client.request("create", {"launch" => rejected_launch})["error"] == "invalid_request"
  rejected_launch["arguments"] = []
  rejected_launch["executable"] = "/qterm-test-no-executable"
  raise "Failed exec was reported as a live PTY" unless client.request("create", {"launch" => rejected_launch})["error"] == "process_launch_failed"
  remaining = ensure_ok(client.request("list")).fetch("sessions")
  raise "Failed launch changed existing sessions" unless remaining.length == 1 && remaining.first["id"] == session["id"]
  checks << "bounded_launch_validation_and_exec_failure_leave_live_sessions_intact"
  output = "".b
  cursor = nil
  read_output = lambda do
    response = ensure_ok(client.request("read", target(session).merge("after" => cursor)))
    output << Base64.strict_decode64(response.fetch("data"))
    cursor = response.fetch("cursor")
    session = response.fetch("session")
    response
  end
  wait_for { read_output.call; output.include?("__TICK:11") }
  raise "PTY PID changed after client exit" unless output.include?("__PID:#{session.fetch('pid')}") && session["running"]
  checks << "frontend_process_exit_preserves_same_real_pty_pid_and_output"
  resumed = ensure_ok(client.request("input", target(session).merge("source" => "human", "data" => Base64.strict_encode64("resume-ok\n"))))
  raise "Echo-off input misclassified" unless resumed["echoEnabled"] == false
  session = resumed.fetch("session")
  wait_for { read_output.call; output.include?("__INPUT:resume-ok") }
  checks << "reattach_accepts_input_and_observes_real_echo_off"

  inspection = ensure_ok(client.request("inspectInput", target(session)))
  session = inspection.fetch("session")
  raise "Input inspection missing echo/foreground" unless [true, false].include?(inspection["echoEnabled"]) && inspection.fetch("foregroundPID") > 0
  prepared = target(session).merge("source" => "human", "data" => Base64.strict_encode64("printf '__PREFLIGHT_OK\\n'\n"),
    "expectedEchoEnabled" => inspection.fetch("echoEnabled"), "expectedForegroundPID" => inspection.fetch("foregroundPID"))
  raise "Stale echo preparation accepted" unless client.request("input", prepared.merge("expectedEchoEnabled" => !inspection.fetch("echoEnabled")))["error"] == "input_echo_changed"
  raise "Wrong foreground preparation accepted" unless client.request("input", prepared.merge("expectedForegroundPID" => inspection.fetch("foregroundPID") + 1))["error"] == "input_foreground_changed"
  session = ensure_ok(client.request("input", prepared)).fetch("session")
  wait_for { read_output.call; output.include?("__PREFLIGHT_OK") }
  checks << "real_input_preflight_and_write_time_echo_foreground_validation"

  old_cursor = cursor
  once_id = SecureRandom.uuid
  once_request = target(session).merge("source" => "human", "data" => Base64.strict_encode64("printf '__ONCE\\n'\n"))
  first = ensure_ok(client.request("input", once_request, id: once_id))
  ensure_ok(client.request("input", once_request, id: once_id))
  session = first.fetch("session")
  wait_for { read_output.call; output.include?("__ONCE") }
  raise "Input duplicate executed twice" unless output.scan("__ONCE").length == 1
  raise "Old sequence accepted" unless client.request("input", once_request)["error"] == "control_changed"
  checks << "duplicate_ack_and_stale_sequence_do_not_repeat_input"
  leased = ensure_ok(client.request("acquireControl", target(session).merge("owner" => "probe-agent"))).fetch("session")
  raise "Human input crossed active lease" unless client.request("input", target(leased).merge("source" => "human", "data" => Base64.strict_encode64("bad\n")))["error"] == "control_owned"
  session = ensure_ok(client.request("releaseControl", target(leased))).fetch("session")
  stale = target(leased).merge("source" => "ai", "owner" => "probe-agent", "data" => Base64.strict_encode64("bad\n"))
  raise "Stale AI control crossed human reclaim" unless client.request("input", stale)["error"] == "control_changed"
  checks << "human_reclaim_rejects_stale_ai_control"
  ensure_ok(client.request("resize", target(session).merge("columns" => 97, "rows" => 31)))
  session = ensure_ok(client.request("input", target(session).merge("source" => "human", "data" => Base64.strict_encode64("stty size\n")))).fetch("session")
  wait_for { read_output.call; output.include?("31 97") }
  checks << "resize_reaches_real_pty"

  # The status bridge and inbox now belong to the same independent process as
  # the PTY. Closing a UI connection must not retire its Agent or active gate.
  session = ensure_ok(client.request("input", target(session).merge("source" => "human", "data" => Base64.strict_encode64("printf '__CONTEXT:%s\\n' \"$QTERM_AGENT_CONTEXT\"\n")))).fetch("session")
  wait_for { read_output.call; output.include?("__CONTEXT:") }
  context_path = output[/__CONTEXT:([^\r\n]+)/, 1]
  raise "Context escaped private fixture" unless File.realpath(context_path).start_with?(root + "/native-tools/native-agent-contexts/")
  context = JSON.parse(File.read(context_path))
  native = RuntimeProbeNativeClient.new(context)
  grant = ensure_ok(native.request("bind_native_agent", {"agentKind" => "willdeep", "nativeAgentToken" => context.fetch("token")})).fetch("agentGrant")
  head = ensure_ok(client.request("readEvents")).fetch("events").fetch("nextCursor")
  identity = {"sessionID" => SecureRandom.uuid, "taskID" => SecureRandom.uuid, "gateID" => SecureRandom.uuid}
  report = grant.merge("sequence" => 1, "activity" => "blocked", "blockReason" => "approval", "context" => identity)
  ensure_ok(native.request("report_agent_state", {"agentReport" => report}))
  inbox = ensure_ok(client.request("listAttention", {"sessionID" => session.fetch("id")})).fetch("attention")
  raise "Native approval not in shared inbox" unless inbox.length == 1 && inbox.first["kind"] == "approval"
  first_attention = inbox.first
  ensure_ok(client.request("acknowledgeAttention", {"attentionID" => first_attention.fetch("id"), "attentionVersion" => first_attention.fetch("version")}))
  client.close
  client = nil
  ensure_ok(native.request("report_agent_state", {"agentReport" => report.merge("sequence" => 2)}))
  client = RuntimeProbeClient.new(root)
  session = ensure_ok(client.request("list")).fetch("sessions").find { |info| info["id"] == session["id"] }
  raise "Native Agent lost on UI reconnect" unless session.dig("agent", "activity") == "blocked" && session.dig("agent", "reportSequence") == 2
  inbox = ensure_ok(client.request("listAttention", {"sessionID" => session.fetch("id")})).fetch("attention")
  raise "Read approval was resolved or duplicated" unless inbox.length == 1 && inbox.first["id"] == first_attention["id"] && inbox.first["readAt"]
  invalid_control = target(session).merge("capability" => grant.fetch("token"), "source" => "ai", "data" => Base64.strict_encode64("bad\n"))
  raise "Status grant allowed input" unless client.request("input", invalid_control)["error"] == "invalid_capability"
  raise "Native bridge accepted input" if native.request("input", {"nativeAgentToken" => context.fetch("token")})["ok"]
  checks << "native_status_and_read_unresolved_approval_survive_ui_disconnect_without_input_authority"

  next_identity = identity.merge("gateID" => SecureRandom.uuid)
  ensure_ok(native.request("report_agent_state", {"agentReport" => report.merge("sequence" => 3, "context" => next_identity)}))
  inbox = ensure_ok(client.request("listAttention", {"sessionID" => session.fetch("id")})).fetch("attention")
  raise "Consecutive gate collapsed into read approval" unless inbox.length == 1 && inbox.first["id"] != first_attention["id"] && !inbox.first["readAt"]
  completed = grant.merge("sequence" => 4, "activity" => "idle", "result" => "completed", "context" => identity.reject { |key, _| key == "gateID" })
  ensure_ok(native.request("report_agent_state", {"agentReport" => completed}))
  raise "Stale status sequence accepted" if native.request("report_agent_state", {"agentReport" => completed})["ok"]
  ensure_ok(native.request("report_agent_state", {"agentReport" => completed.merge("sequence" => 5)}))
  inbox = ensure_ok(client.request("listAttention", {"sessionID" => session.fetch("id")})).fetch("attention")
  raise "Completion was duplicated or left approval active" unless inbox.length == 1 && inbox.first["kind"] == "completed"
  event_batch = ensure_ok(client.request("readEvents", {"eventAfter" => head})).fetch("events")
  raise "Shared event metadata leaked capabilities" if [grant.fetch("token"), context.fetch("token"), before_capability].any? { |secret| JSON.generate(event_batch).include?(secret) }
  checks << "shared_gate_dedup_completion_and_private_event_journal"

  subscriber = RuntimeProbeClient.new(root)
  ensure_ok(subscriber.request("subscribe", target(session).merge("after" => cursor)))
  session = ensure_ok(client.request("input", target(session).merge("source" => "human", "data" => Base64.strict_encode64("printf '__SUBSCRIPTION\\n'\n")))).fetch("session")
  wait_for do
    frame = subscriber.receive
    Base64.strict_decode64(frame.fetch("data")).include?("__SUBSCRIPTION")
  end
  subscriber.close
  checks << "stream_subscription_and_detach"

  quiet_launch = {"executable" => "/bin/sh", "arguments" => ["-c", "sleep 45"], "directory" => root,
    "environment" => {"PATH" => "/usr/bin:/bin", "HOME" => root, "TERM" => "xterm-256color"}, "columns" => 80, "rows" => 24}
  quiet = ensure_ok(client.request("create", {"launch" => quiet_launch})).fetch("session")
  observer = RuntimeProbeClient.new(root)
  ensure_ok(observer.request("subscribe", target(quiet)))
  quiet = ensure_ok(client.request("acquireControl", target(quiet).merge("owner" => "quiet-agent"))).fetch("session")
  observed = ensure_ok(observer.receive).fetch("session")
  raise "Viewer missed acquired lease" unless observed["controlOwner"] == "quiet-agent"
  previous_expiry = quiet.fetch("controlExpiresAt")
  sleep 0.05
  quiet = ensure_ok(client.request("renewControl", target(quiet).merge("owner" => "quiet-agent"))).fetch("session")
  observed = ensure_ok(observer.receive).fetch("session")
  raise "Viewer missed renewed expiry" unless observed.fetch("controlExpiresAt") == quiet.fetch("controlExpiresAt") && observed.fetch("controlExpiresAt") > previous_expiry
  quiet = ensure_ok(client.request("releaseControl", target(quiet))).fetch("session")
  raise "Viewer missed reclaim" unless ensure_ok(observer.receive).fetch("session")["controlOwner"].nil?
  checks << "lease_renewal_projects_to_other_idle_viewers"
  client.close
  heartbeat_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  heartbeat = ensure_ok(observer.receive(timeout: 20))
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - heartbeat_started
  raise "Idle heartbeat did not preserve quiet PTY" unless heartbeat.fetch("session").fetch("pid") == quiet.fetch("pid") && heartbeat.fetch("session").fetch("running") && Base64.strict_decode64(heartbeat.fetch("data")).empty?
  raise "Expected a periodic heartbeat" unless elapsed >= 10 && elapsed < 20
  observer.close
  client = RuntimeProbeClient.new(root)
  ensure_ok(client.request("close", target(quiet)))
  checks << "idle_subscription_heartbeat_prevents_viewer_timeout"

  # A stalled output consumer must not hold the PTY or fast reader hostage.
  slow = RuntimeProbeClient.new(root)
  ensure_ok(slow.request("subscribe", target(session).merge("after" => cursor)))

  # Exceed the 2 MiB client queue even after socket buffering; keep testing
  # actual backpressure rather than relying on the 30-second write timeout.
  session = ensure_ok(client.request("input", target(session).merge("source" => "human", "data" => Base64.strict_encode64("head -c 4194304 /dev/zero; printf '__BULK_DONE\\n'\n")))).fetch("session")
  wait_for(15) { read_output.call; output.include?("__BULK_DONE") }
  replay = ensure_ok(client.request("read", target(session).merge("after" => old_cursor)))
  raise "Evicted history did not expose gap" unless replay["hasGap"] && Base64.strict_decode64(replay["data"]).bytesize <= 65_536
  future = {"generation" => session.fetch("generation"), "offset" => replay.fetch("latestOffset") + 1}
  raise "Future cursor accepted" unless client.request("read", target(session).merge("after" => future))["error"] == "future_cursor"
  raise "Generation mismatch accepted" unless client.request("read", target(session).merge("generation" => SecureRandom.uuid))["error"] == "generation_changed"
  checks << "bounded_replay_explicit_gap_and_cursor_rejection"
  disconnected = false
  64.times do
    begin
      slow.receive(timeout: 6)
    rescue EOFError
      disconnected = true
      break
    end
  end
  slow.close
  raise "Slow output consumer was not bounded/disconnected" unless disconnected
  checks << "slow_consumer_disconnected_while_pty_and_fast_reader_continue"

  hostile = RuntimeProbeClient.new(root)
  hostile.send_bytes("x" * 140_000)
  begin
    hostile.receive
    raise "Oversized frame accepted"
  rescue EOFError, Errno::ECONNRESET
    checks << "oversized_frame_disconnects_only_offending_client"
  ensure
    hostile.close
  end
  spare_launch = {"executable" => "/bin/sh", "arguments" => ["-i"], "directory" => root,
    "environment" => {"PATH" => "/usr/bin:/bin", "HOME" => root, "TERM" => "xterm-256color"}, "columns" => 80, "rows" => 24}
  spare = ensure_ok(client.request("create", {"launch" => spare_launch})).fetch("session")
  ensure_ok(client.request("close", target(session)))
  remaining = ensure_ok(client.request("list")).fetch("sessions")
  raise "Close affected another live terminal" unless remaining.length == 1 && remaining.first["pid"] == spare["pid"] && remaining.first["running"]
  ensure_ok(client.request("close", target(spare)))
  wait_for { ensure_ok(client.request("list")).fetch("sessions").empty? }
  [session, spare].each do |info|
    wait_for do
      begin
        Process.kill(0, info.fetch("pid"))
        false
      rescue Errno::ESRCH
        true
      end
    end
  end
  checks << "explicit_close_removes_only_target"
  ensure_ok(client.request("shutdownIfEmpty"))
  wait_for { Process.waitpid(server, Process::WNOHANG) }
  raise "Empty service did not exit cleanly" unless $?.success?
  server = nil
  checks << "shutdown_only_after_all_owned_terminals_are_explicitly_closed"
  passed = true
rescue StandardError => error
  failure = error.message
ensure
  begin
    client.request("close", target(session)) if client && session && !passed
  rescue StandardError
    # The only remaining cleanup target is our own service child below.
  end
  client&.close
  if server
    begin
      unless Process.waitpid(server, Process::WNOHANG)
        Process.kill("TERM", server)
        Process.waitpid(server)
      end
    rescue Errno::ESRCH, Errno::ECHILD
      # Already exited; never look up or terminate a different process.
    end
  end
  report = {"generatedAt" => Time.now.iso8601, "passed" => passed, "failure" => failure,
    "binarySHA256" => Digest::SHA256.file(binary).hexdigest, "checks" => checks,
    "scope" => "独立真实 PTY 服务及共用 Agent/待处理/事件归约跨客户端；原生状态采用协议夹具，尚未接 QTerm UI 或产品安装路径",
    "fixtureDirectory" => passed ? nil : root}
  FileUtils.mkdir_p(File.dirname(prefix))
  File.write(prefix + ".json", JSON.pretty_generate(report) + "\n")
  File.write(prefix + ".md", (["# 独立终端后台验证", "", "通过：#{passed}", "失败：#{failure || '无'}", "", report["scope"], ""] + checks.map { |check| "- #{check}" } + [""]).join("\n"))
  FileUtils.remove_entry(root) if passed
end
puts JSON.generate({"passed" => passed, "failure" => failure, "report" => prefix + ".json"})
exit(passed ? 0 : 1)
