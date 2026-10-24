#!/usr/bin/env ruby
# Actual WillDeep TUI/Runtime over a PTY, with loopback-only model and status fixtures.
require "json"
require "socket"
require "pty"
require "io/console"
require "tmpdir"
require "fileutils"
require "securerandom"
require "open3"
require "digest"
require "time"
require "net/http"
require "base64"
require "shellwords"
require_relative "support/runtime_probe_client"
require_relative "support/runtime_wait_file_client"
STDOUT.sync = true

binary = File.expand_path(ARGV.fetch(0))
prefix = File.expand_path(ARGV.fetch(1, "reports/willdeep_native_cli_probe"))
mode = ARGV.fetch(2, "tui")
abort "Unsupported probe mode" unless %w[tui backend-tui qa-ui headless-complete headless-blocked].include?(mode)
qa_ui = mode == "qa-ui"
use_backend = %w[backend-tui qa-ui].include?(mode)
tui_mode = %w[tui backend-tui qa-ui].include?(mode)
qa_metadata = qa_ui ? JSON.parse(File.read(ARGV.fetch(3))) : nil
qa_terminal_id = qa_ui ? ARGV.fetch(4) : nil
wait_cli = use_backend && !qa_ui && ARGV[4] ? File.expand_path(ARGV[4]) : nil
abort "Wait CLI source missing" if wait_cli && !File.file?(wait_cli)
if qa_ui && %w[resume finish].any? { |name| File.exist?("#{prefix}.#{name}") }
  abort "QA checkpoint files already exist; use a new report prefix"
end
backend_binary = if qa_ui
  File.join(qa_metadata.fetch("app"), "Contents/Helpers/qterm-runtime")
elsif use_backend
  File.expand_path(ARGV.fetch(3))
end
abort "WillDeep binary missing" unless File.executable?(binary)
# Darwin sockaddr_un has a short path limit; the user's TMPDIR may exceed it.
root = Dir.mktmpdir("qtn-", "/private/tmp")
File.chmod(0o700, root)
%w[home workspace requests responses].each { |name| Dir.mkdir(File.join(root, name), 0o700) }
def write_private(path, value)
  temporary = "#{path}.pending"
  File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(value) }
  File.rename(temporary, path)
end

context = {"protocolVersion" => 1, "tabID" => SecureRandom.uuid, "root" => root,
           "token" => SecureRandom.uuid + SecureRandom.uuid}
write_private(File.join(root, "context.json"), JSON.generate(context))
grant = {"instanceID" => SecureRandom.uuid, "runID" => SecureRandom.uuid, "token" => SecureRandom.hex(32)}
states = []
errors = []
mutex = Mutex.new
stop = false
sequence = 0
lost_response = false
bridge = Thread.new do
  until stop
    Dir.glob(File.join(root, "requests", "*.json")).each do |path|
      request = JSON.parse(File.read(path))
      File.delete(path)
      response = {"id" => request.fetch("id"), "ok" => true}
      raise "Wrong terminal" unless request["tab"].downcase == context["tabID"].downcase
      case request["action"]
      when "bind_native_agent"
        raise "Wrong status capability" unless request["nativeAgentToken"] == context["token"] && request["agentKind"] == "willdeep"
        response["agentGrant"] = grant
      when "report_agent_state"
        report = request.fetch("agentReport")
        raise "Status credential mismatch" unless grant.all? { |key, value| report[key] == value }
        raise "Non-monotonic report" unless report["sequence"] > sequence
        sequence = report["sequence"]
        metadata = report.slice("sequence", "activity", "blockReason", "result", "context")
        metadata["observedAt"] = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        mutex.synchronize { states << metadata }
        # A lost acknowledgement must reserve the sequence and retry without rebinding.
        if report["activity"] == "blocked" && !lost_response
          lost_response = true
          next
        end
      else
        raise "Unexpected status operation"
      end
      write_private(File.join(root, "responses", "#{request.fetch('id')}.json"), JSON.generate(response))
    end
    sleep 0.02
  end
rescue StandardError => error
  mutex.synchronize { errors << error.message }
end unless use_backend

server = TCPServer.new("127.0.0.1", 0)
port = server.addr[1]
requests = 0
provider = Thread.new do
  until stop
    socket = server.accept
    request = socket.gets
    headers = {}
    while (line = socket.gets) && line != "\r\n"
      key, value = line.split(":", 2)
      headers[key.downcase] = value.to_s.strip
    end
    body = headers["content-length"].to_i.positive? ? socket.read(headers["content-length"].to_i) : ""
    if request.start_with?("GET ")
      payload = JSON.generate({"data" => [{"id" => "mock-model", "object" => "model"}]})
      content_type = "application/json"
    else
      input = JSON.parse(body)
      requests += 1
      message = if requests == 1 && mode != "headless-complete"
        {"role" => "assistant", "content" => nil, "tool_calls" => [{"id" => "native-probe-call", "type" => "function",
          "function" => {"name" => "run_command", "arguments" => JSON.generate({"command" => "printf qterm_native_probe"})}}]}
      else
        {"role" => "assistant", "content" => "qterm_native_complete"}
      end
      if input["stream"]
        delta = message.dup
        delta["tool_calls"] = delta["tool_calls"].map { |call| call.merge("index" => 0) } if delta["tool_calls"]
        chunks = [{"id" => "native-probe", "choices" => [{"index" => 0, "delta" => delta, "finish_reason" => nil}]},
          {"id" => "native-probe", "choices" => [{"index" => 0, "delta" => {}, "finish_reason" => message["tool_calls"] ? "tool_calls" : "stop"}]}]
        payload = chunks.map { |chunk| "data: #{JSON.generate(chunk)}\n\n" }.join + "data: [DONE]\n\n"
        content_type = "text/event-stream"
      else
        payload = JSON.generate({"id" => "native-probe", "choices" => [{"index" => 0, "message" => message,
          "finish_reason" => message["tool_calls"] ? "tool_calls" : "stop"}]})
        content_type = "application/json"
      end
    end
    socket.write("HTTP/1.1 200 OK\r\nContent-Type: #{content_type}\r\nContent-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
    socket.close
  end
rescue IOError, Errno::EBADF
  raise unless stop
rescue StandardError => error
  mutex.synchronize { errors << error.message }
end

config = ["version = 1", 'default_provider = "mock"', "", "[agent]", 'approval = "strict"', "max_turns = 4",
  "auto_dispatch_read_only = false", "auto_title = false", "input_suggestions = false", "sandbox = false", 'language = "en"',
  "", "[ui]", "check_updates = false", "", "[providers.mock]", 'provider = "openai-compatible"', 'api = "chat-completions"',
  "api_base = \"http://127.0.0.1:#{port}/v1\"", 'api_key = "integration-test-only"', 'model = "mock-model"', ""].join("\n")
write_private(File.join(root, "config.toml"), config)
env = ENV.keys.grep(/\A(?:WILLDEEP_|OPENAI_|ANTHROPIC_)/).to_h { |key| [key, nil] }
env.merge!("WILLDEEP_HOME" => File.join(root, "home"), "QTERM_AGENT_CONTEXT" => File.join(root, "context.json"),
  "WILLDEEP_NO_UPDATE_CHECK" => "1", "TERM" => "xterm-256color")
transcript = "".b
child = nil
runtime_child = nil
backend_child = nil
backend_client = nil
backend_session = nil
previous_agent_instance = nil
backend_watcher = nil
watcher_stop = false
backend_disconnected_seconds = 0
backend_input_diagnostics = []
backend_wait_client = nil
backend_wait_id = nil
backend_wait_result = nil
backend_pending_at_approval = nil
backend_cli_wait_pid = nil
backend_cli_wait_result = nil
backend_output_cursor = nil
backend_dsr_seen = false
backend_dsr_pending = false
backend_device_replies = 0
frontend_exit_status = nil
passed = false
failure = nil
stage = "runtime startup"
begin
  # Own the foreground Runtime as a direct child. Never invoke daemon stop or
  # inspect/terminate processes from the user's normal WILLDEEP_HOME.
  runtime_directory = File.join(root, "home", "runtime")
  Dir.mkdir(runtime_directory, 0o700)
  runtime_lock = SecureRandom.hex(16)
  write_private(File.join(runtime_directory, "daemon.lock"),
    JSON.generate({"token" => runtime_lock, "created_at" => Time.now.to_i}))
  runtime_env = env.merge("WILLDEEP_DAEMON_LOCK_TOKEN" => runtime_lock, "QTERM_AGENT_CONTEXT" => nil)
  runtime_log = File.open(File.join(root, "runtime.log"), File::WRONLY | File::CREAT | File::EXCL, 0o600)
  runtime_child = Process.spawn(runtime_env, binary, "--config", File.join(root, "config.toml"), "daemon", "run",
    in: File::NULL, out: runtime_log, err: runtime_log)
  runtime_log.close
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 25
  loop do
    state_path = File.join(runtime_directory, "daemon.json")
    if File.file?(state_path)
      runtime_state = JSON.parse(File.read(state_path))
      raise "Fixture Runtime PID differs from owned child" unless runtime_state["pid"] == runtime_child
      uri = URI("http://#{runtime_state.fetch('address')}/v1/health")
      raise "Fixture Runtime is not loopback" unless uri.host == "127.0.0.1"
      response = Net::HTTP.start(uri.host, uri.port, nil, open_timeout: 1, read_timeout: 1) do |http|
        request = Net::HTTP::Get.new(uri)
        request["x-willdeep-token"] = runtime_state.fetch('token')
        http.request(request)
      end
      break if response.is_a?(Net::HTTPSuccess)
    end
    raise "Owned Runtime exited before readiness" if Process.waitpid(runtime_child, Process::WNOHANG)
    raise "Owned Runtime startup timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    sleep 0.05
  end
  # Runtime workspace policy overrides the process-local TOML approval setting.
  # Register only this fixture directory, with strict policy, before submitting.
  _, _, registration = Open3.capture3(runtime_env, binary, "--config", File.join(root, "config.toml"),
    "daemon", "register-workspace", File.join(root, "workspace"), "--access", "strict")
  raise "Could not register strict fixture workspace" unless registration.success?
  stage = "TUI initial state"
  arguments = ["--config", File.join(root, "config.toml"), "--workspace", File.join(root, "workspace"), "--new-session"]
  arguments += ["--no-tui", "Run the native integration probe."] unless tui_mode
  if use_backend
    backend_root = qa_ui ? qa_metadata.fetch("backend") : File.join(root, "qterm")
    if qa_ui
      qa_root = File.realpath(qa_metadata.fetch("root"))
      tools_root = File.join(qa_root, "Tools")
      raise "Not an isolated QA fixture" unless qa_root.match?(%r{\A/private/tmp/qterm-native-qa-[0-9a-f]+\z})
      [qa_root, tools_root, backend_root].each do |path|
        info = File.lstat(path)
        raise "Unsafe QA directory" unless info.directory? && info.uid == Process.uid && info.mode & 0o077 == 0
      end
      expected_root = "/private/tmp/qrt-ui-#{Process.uid}-#{Digest::SHA256.hexdigest(tools_root)[0, 20]}"
      raise "QA backend namespace mismatch" unless backend_root == expected_root && qa_metadata.fetch("tools") == tools_root
    else
      backend_log = File.open(File.join(root, "qterm-runtime.log"), File::WRONLY | File::CREAT | File::EXCL, 0o600)
      backend_child = Process.spawn(backend_binary, "--root", backend_root, in: File::NULL, out: backend_log, err: backend_log)
      backend_log.close
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
      until File.socket?(File.join(backend_root, "runtime.sock")) && File.file?(File.join(backend_root, "ui-capability"))
        raise "Owned QTerm backend exited" if Process.waitpid(backend_child, Process::WNOHANG)
        raise "Owned QTerm backend startup timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.05
      end
    end
    checked = lambda do |response|
      raise "QTerm backend rejected #{response['action']}: #{response['error']}" unless response["ok"]
      response
    end
    backend_client = RuntimeProbeClient.new(backend_root)
    backend_request = lambda do |action, fields|
      connection = RuntimeProbeClient.new(backend_root)
      begin
        checked.call(connection.request(action, fields))
      ensure
        connection.close
      end
    end
    child_environment = ENV.to_h.slice("PATH", "USER", "LOGNAME", "SHELL", "LANG", "LC_ALL", "TMPDIR").merge(env).reject { |_, value| value.nil? }
    child_environment["HOME"] = File.join(root, "home")
    launch = {"executable" => binary, "arguments" => arguments, "directory" => File.join(root, "workspace"),
      "environment" => child_environment, "columns" => 140, "rows" => 40}
    if qa_ui
      backend_session = checked.call(backend_client.request("list", {})).fetch("sessions").find { |item| item["id"].casecmp?(qa_terminal_id) }
      previous_agent = backend_session&.fetch("agent", nil)
      raise "QA terminal missing/busy" unless backend_session && backend_session["running"] && backend_session["controlOwner"].nil? &&
        (previous_agent.nil? || previous_agent["activity"] == "exited")
      previous_agent_instance = previous_agent&.fetch("instanceID", nil)
      inspection = checked.call(backend_client.request("inspectInput", {"sessionID" => backend_session.fetch("id"), "generation" => backend_session.fetch("generation")}))
      raise "QA terminal is not an idle shell" unless inspection["foregroundPID"] == backend_session["pid"]
      launch_environment = env.reject { |key, _| key == "QTERM_AGENT_CONTEXT" }.merge("HOME" => File.join(root, "home"))
      command = ["/usr/bin/env"] + launch_environment.filter_map { |key, value| value.nil? ? ["-u", key] : nil }.flatten
      command += launch_environment.filter_map { |key, value| "#{key}=#{value}" unless value.nil? }
      command += [binary] + arguments
      launch_script = File.join(root, "launch.sh")
      write_private(launch_script, "#!/bin/sh\nexec #{Shellwords.join(command)}\n")
      puts JSON.generate({"checkpoint" => "launch-in-qa-ui", "command" => Shellwords.join(["/bin/sh", launch_script]), "terminalID" => backend_session["id"], "pid" => backend_session["pid"]})
    else
      backend_session = checked.call(backend_client.request("create", {"launch" => launch})).fetch("session")
    end
    backend_target = lambda do
      {"sessionID" => backend_session.fetch("id"), "generation" => backend_session.fetch("generation"),
       "controlEpoch" => backend_session.fetch("controlEpoch"), "inputSequence" => backend_session.fetch("nextInputSequence")}
    end
    send_input = lambda do |text|
      raise "QA UI input must be performed through the actual application" if qa_ui
      result = backend_request.call("input", backend_target.call.merge("source" => "human", "data" => Base64.strict_encode64(text)))
      backend_session = result.fetch("session")
      backend_input_diagnostics << {"bytes" => text.bytesize, "echoEnabled" => result["echoEnabled"], "foregroundPID" => result["foregroundPID"], "ptyPID" => backend_session["pid"]}
      puts JSON.generate({"probe" => "backend_input", "pid" => backend_session["pid"], "bytes" => text.bytesize, "echoEnabled" => result["echoEnabled"]})
    end
    start_watcher = lambda do
      Thread.new do
        connection = RuntimeProbeClient.new(backend_root)
        cursor = backend_output_cursor
        until stop || watcher_stop
          response = checked.call(connection.request("read", backend_target.call.merge("after" => cursor)))
          cursor = response.fetch("cursor")
          backend_output_cursor = cursor
          data = Base64.strict_decode64(response.fetch("data"))
          agent = response.dig("session", "agent")
          mutex.synchronize do
            transcript = (transcript + data).byteslice(-32_768, 32_768) || transcript + data
            if !backend_dsr_seen && transcript.include?("\e[5n")
              backend_dsr_seen = true
              backend_dsr_pending = true
            end
            if agent && agent["instanceID"] != previous_agent_instance && states.last&.fetch("sequence", nil) != agent["reportSequence"]
              metadata = agent.slice("activity", "blockReason", "context")
              metadata["result"] = agent["lastResult"] if agent["lastResult"]
              metadata["sequence"] = agent["reportSequence"]
              metadata["observedAt"] = Process.clock_gettime(Process::CLOCK_MONOTONIC)
              states << metadata
            end
          end
          sleep 0.05
        end
      rescue StandardError => error
        mutex.synchronize { errors << error.message } unless stop || watcher_stop
      ensure
        connection&.close
      end
    end
    backend_watcher = start_watcher.call
  else
    read, write, child = PTY.spawn(env, binary, *arguments)
    read.winsize = [40, 140]
    write.sync = true
    send_input = ->(text) { write.write(text) }
    reader = Thread.new do
      loop do
        data = read.readpartial(8192)
        mutex.synchronize do
          transcript = (transcript + data).byteslice(-32_768, 32_768) || transcript + data
          if !backend_dsr_seen && transcript.include?("\e[5n")
            backend_dsr_seen = true
            backend_dsr_pending = true
          end
        end
      end
    rescue EOFError, Errno::EIO, IOError
      nil
    end
  end
  wait_for = lambda do |seconds, &condition|
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
    until mutex.synchronize { condition.call(states) }
      if tui_mode && !qa_ui && backend_dsr_pending
        backend_dsr_pending = false
        send_input.call("\e[0n")
        backend_device_replies += 1
      end
      raise "Native integration timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      raise "Fixture service failed" unless mutex.synchronize { errors.empty? }
      sleep 0.05
    end
  end
  if tui_mode
    # The native reporter starts before the TUI enables raw input. Sending on
    # the first idle report can be flushed by terminal initialization.
    wait_for.call(qa_ui ? 600 : 25) { |items| items.any? { |item| item["activity"] == "idle" } && transcript.include?("Ready") }
    if qa_ui
      puts JSON.generate({"checkpoint" => "prompt-in-qa-ui", "prompt" => "Run the native integration probe."})
    else
      send_input.call("Run the native integration probe.\r")
    end
    stage = "approval"
    wait_for.call(qa_ui ? 600 : 30) { |items| items.any? { |item| item["activity"] == "blocked" && item["blockReason"] == "approval" } }
    stage = "retry and heartbeat"
    if use_backend
      pending = backend_request.call("listAttention", {"sessionID" => backend_session.fetch("id")}).fetch("attention")
      backend_pending_at_approval = pending.map { |item| item["kind"] }
      raise "Real CLI approval not in backend inbox" unless pending.length == 1 && pending.first["kind"] == "approval"
      pending_id = pending.first.fetch("id")
      original_pid = backend_session.fetch("pid")
      original_generation = backend_session.fetch("generation")
      original_foreground_pid = backend_request.call("inspectInput", backend_target.call).fetch("foregroundPID")
      capability_snapshot = backend_request.call("list", {})
      if !qa_ui && capability_snapshot.fetch("features", []).include?("event_wait_v1")
        original_agent = capability_snapshot.fetch("sessions").find { |item| item["id"] == backend_session["id"] }.fetch("agent")
        backend_wait_client = RuntimeWaitFileClient.new(backend_root)
        after = backend_wait_client.request("read_session_events").fetch("eventBatch").fetch("nextCursor")
        backend_wait_id = backend_wait_client.send("wait_session", {"controlID" => SecureRandom.uuid,
          "waitSpec" => {"condition" => "agentState", "after" => after, "tabID" => backend_session["id"],
            "instanceID" => original_agent.fetch("instanceID"), "runID" => original_agent.fetch("runID"),
            "activity" => "idle", "timeoutSeconds" => 60}})
        backend_wait_client.consumed(backend_wait_id)
        if wait_cli
          home = File.join(root, "event-cli-home")
          tools = File.join(home, "Library/Application Support/QTerm/Tools")
          FileUtils.mkdir_p(tools, mode: 0o700)
          ui_epoch = SecureRandom.uuid
          metadata = {"appEpoch" => ui_epoch, "pid" => 2147483647, "version" => capability_snapshot.fetch("version"),
            "cursor" => {"appEpoch" => ui_epoch, "sequence" => 0},
            "backend" => {"schemaVersion" => 1, "root" => File.join(backend_root, "native-tools"), "cursor" => after}}
          File.open(File.join(tools, "runtime.json"), File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(JSON.generate(metadata)) }
          backend_cli_stdout = File.join(root, "event-cli.stdout.json")
          backend_cli_stderr = File.join(root, "event-cli.stderr.log")
          output = File.open(backend_cli_stdout, File::WRONLY | File::CREAT | File::EXCL, 0o600)
          error = File.open(backend_cli_stderr, File::WRONLY | File::CREAT | File::EXCL, 0o600)
          spec = {"condition" => "agentState", "after" => after, "tabID" => backend_session["id"],
            "instanceID" => original_agent.fetch("instanceID"), "runID" => original_agent.fetch("runID"), "activity" => "idle", "timeoutSeconds" => 60}
          backend_cli_wait_pid = Process.spawn({"HOME" => home, "PATH" => "/usr/bin:/bin"},
            "/usr/bin/ruby", wait_cli, "wait", JSON.generate(spec), in: File::NULL, out: output, err: error)
          output.close; error.close
          wait_for.call(10) { |_| backend_request.call("diagnostics", {}).fetch("pendingWaits") == 2 }
        end
      end
      watcher_stop = true
      backend_watcher.join(6)
      raise "State reader did not detach" if backend_watcher.alive?
      backend_client.close
      backend_client = nil
      disconnected_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      # Deliberately no connected UI clients for one heartbeat interval. The CLI
      # and native file endpoint remain owned by the independent backend.
      if qa_ui
        puts JSON.generate({"checkpoint" => "quit-and-relaunch-qa-ui", "pendingID" => pending_id, "pid" => original_pid,
          "foregroundPID" => original_foreground_pid, "generation" => original_generation, "resumeFile" => "#{prefix}.resume"})
        wait_for.call(900) { |_| File.file?("#{prefix}.resume") }
      else
        sleep 31
        backend_disconnected_seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - disconnected_at
        raise "Service wait completed before original approval was answered" if backend_wait_id && backend_wait_client.ready?(backend_wait_id)
        if backend_cli_wait_pid && Process.waitpid(backend_cli_wait_pid, Process::WNOHANG)
          backend_cli_wait_pid = nil
          raise "Generated CLI wait exited before original approval was answered"
        end
      end
      backend_client = RuntimeProbeClient.new(backend_root)
      restored = backend_request.call("list", {}).fetch("sessions").find { |session| session["id"] == backend_session["id"] }
      raise "WillDeep PTY did not survive UI detach" unless restored && restored["pid"] == original_pid && restored["running"]
      raise "WillDeep PTY generation changed" unless restored["generation"] == original_generation
      backend_session = restored
      restored_foreground_pid = backend_request.call("inspectInput", backend_target.call).fetch("foregroundPID")
      raise "WillDeep foreground process changed during UI detach" unless restored_foreground_pid == original_foreground_pid
      raise "WillDeep approval resolved during UI detach" unless restored.dig("agent", "activity") == "blocked"
      pending = backend_request.call("listAttention", {"sessionID" => backend_session.fetch("id")}).fetch("attention")
      raise "Pending approval duplicated/lost while UI detached" unless pending.length == 1 && pending.first["id"] == pending_id
      if qa_ui
        wait_for.call(10) do |_|
          ui = JSON.parse(File.read(File.join(qa_metadata.fetch("tools"), "state.json")))
          entries = ui.fetch("attentionItems").select { |item| item.fetch("tabID").casecmp?(backend_session.fetch("id")) }
          entries.length == 1 && entries.first["id"].casecmp?(pending_id) && entries.first["kind"] == "approval"
        end
      end
      watcher_stop = false
      backend_watcher = start_watcher.call
    end
    wait_for.call(45) { |items| items.count { |item| item["activity"] == "blocked" } >= (use_backend ? 2 : 3) }
    if qa_ui
      puts JSON.generate({"checkpoint" => "approve-in-qa-ui", "terminalID" => backend_session["id"]})
    else
      send_input.call("y")
    end
  end
  stage = mode == "headless-blocked" ? "headless pending approval" : "completed result"
  if mode == "headless-blocked"
    wait_for.call(30) { |items| items.any? { |item| item["activity"] == "blocked" && item["blockReason"] == "approval" } }
  else
    wait_for.call(qa_ui ? 600 : 30) { |items| items.any? { |item| item["result"] == "completed" } }
  end
  observed = mutex.synchronize { states.map(&:dup) }
  blocked = observed.select { |item| item["activity"] == "blocked" }
  unless mode == "headless-complete"
    raise "Heartbeat changed gate identity" unless blocked.map { |item| item["context"] }.uniq.length == 1
    raise "No true Runtime task identity" unless blocked.first.dig("context", "taskID").to_s.match?(/\A[0-9a-f-]{36}\z/i)
    raise "No true gate identity" unless blocked.first.dig("context", "gateID").to_s.match?(/\A[0-9a-f-]{36}\z/i)
  end
  if tui_mode
    raise "Heartbeat did not cover 30 seconds" unless blocked.last["observedAt"] - blocked.first["observedAt"] >= 30
  end
  raise "Spurious terminal result during Runtime completion" if observed.any? { |item| %w[failed interrupted unknown].include?(item["result"]) }
  completed = observed.find { |item| item["result"] == "completed" }
  if tui_mode
    raise "Completion belongs to a different task" unless completed["context"].slice("sessionID", "taskID") == blocked.first["context"].slice("sessionID", "taskID")
    if use_backend
      pending = backend_request.call("listAttention", {"sessionID" => backend_session.fetch("id")}).fetch("attention")
      raise "Real CLI completion duplicated or approval left active" unless pending.length == 1 && pending.first["kind"] == "completed"
      if backend_wait_id
        waited = backend_wait_client.receive(backend_wait_id)
        raise "Original WillDeep service wait failed" unless waited["ok"] && waited.dig("waitResult", "outcome") == "matched"
        backend_wait_result = waited.fetch("waitResult")
        raise "Wait matched another task or a non-result idle" unless backend_wait_result.dig("agent", "lastResult") == "completed" &&
          backend_wait_result.fetch("agent").fetch("context").slice("sessionID", "taskID") == blocked.first.fetch("context").slice("sessionID", "taskID")
      end
      if backend_cli_wait_pid
        wait_for.call(10) { |_| Process.waitpid(backend_cli_wait_pid, Process::WNOHANG) }
        status = $?.exitstatus
        backend_cli_wait_pid = nil
        raise "Generated CLI backend wait failed" unless status == 0
        response = JSON.parse(File.read(backend_cli_stdout))
        backend_cli_wait_result = response.fetch("waitResult")
        raise "Generated CLI wait matched another result" unless response["ok"] && backend_cli_wait_result["outcome"] == "matched" &&
          backend_cli_wait_result.dig("agent", "lastResult") == "completed" &&
          backend_cli_wait_result.fetch("agent").fetch("context").slice("sessionID", "taskID") == blocked.first.fetch("context").slice("sessionID", "taskID")
        raise "Generated CLI public time format changed" unless backend_cli_wait_result.dig("agent", "updatedAt").is_a?(String)
      end
      if qa_ui
        wait_for.call(10) do |_|
          ui = JSON.parse(File.read(File.join(qa_metadata.fetch("tools"), "state.json")))
          entries = ui.fetch("attentionItems").select { |item| item.fetch("tabID").casecmp?(backend_session.fetch("id")) }
          entries.length == 1 && entries.first["kind"] == "completed"
        end
      end
    end
    if qa_ui
      puts JSON.generate({"checkpoint" => "completed-in-qa-ui", "finishFile" => "#{prefix}.finish"})
      wait_for.call(600) { |_| File.file?("#{prefix}.finish") }
    else
      send_input.call("/exit\r")
    end
  else
    stage = "headless process exit"
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    until Process.waitpid(child, Process::WNOHANG)
      raise "Headless frontend did not exit" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 0.05
    end
    frontend_exit_status = $?.exitstatus
    if mode == "headless-complete" && frontend_exit_status != 0
      raise "Completed headless command returned a nonzero exit status"
    end
    observed = mutex.synchronize { states.map(&:dup) }
    raise "Headless return retired the Runtime task" if observed.any? { |item| item["activity"] == "exited" }
  end
  raise "Fixture service failed" unless mutex.synchronize { errors.empty? }
  passed = true
rescue StandardError => error
  failure = "#{stage}: #{error.message}"
ensure
  if backend_cli_wait_pid
    begin
      Process.kill("TERM", backend_cli_wait_pid)
      Process.waitpid(backend_cli_wait_pid)
    rescue Errno::ESRCH, Errno::ECHILD
      warn "Owned CLI waiter already exited"
    end
  end
  stop = true
  server.close
  backend_watcher&.join(6)
  if backend_client && backend_session && !qa_ui
    begin
      backend_request.call("close", backend_target.call)
    rescue StandardError
      # Only our explicitly spawned backend child is eligible for cleanup below.
    end
    backend_client.close
  end
  backend_client&.close if qa_ui
  [child, runtime_child, backend_child].compact.each do |owned_pid|
    begin
      # waitpid proves ownership and avoids signalling a recycled PID.
      next if Process.waitpid(owned_pid, Process::WNOHANG)
      Process.kill("TERM", owned_pid)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
      until Process.waitpid(owned_pid, Process::WNOHANG)
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          Process.kill("KILL", owned_pid)
          Process.waitpid(owned_pid)
          break
        end
        sleep 0.05
      end
    rescue Errno::ESRCH, Errno::ECHILD
      # Already reaped or exited. No other PID is considered for cleanup.
    end
  end
  bridge&.join(3)
  provider.join(3)
  write_private(File.join(root, "terminal.bin"), mutex.synchronize { transcript }) unless passed
  report = {"generatedAt" => Time.now.iso8601, "mode" => mode, "passed" => passed, "failure" => failure,
    "scope" => qa_ui ? "实际隔离 QTerm 图形界面 + WillDeep CLI/Runtime；本机 mock 模型；所有输入由原生界面执行，界面动作与退出时长另存独立证据" : (use_backend ? "实际 WillDeep CLI/Runtime + 独立 QTerm 后台真实 PTY/状态桥/待处理；本机 mock 模型；尚非 QTerm 图形界面联调" : "实际 WillDeep TUI/Runtime + PTY；本机模型与状态桥夹具；不等同 QTerm UI 联调或后台保活验收"),
    "fixtureDirectory" => passed ? nil : root,
    "binarySHA256" => Digest::SHA256.file(binary).hexdigest, "modelRequests" => requests,
    "frontendExitStatus" => frontend_exit_status,
    "qtermBackendSHA256" => use_backend ? Digest::SHA256.file(backend_binary).hexdigest : nil,
    "allUIClientsDetachedSeconds" => qa_ui ? nil : backend_disconnected_seconds,
    "backendInputDiagnostics" => backend_input_diagnostics,
    "backendWaitResult" => backend_wait_result,
    "backendPendingKindsAtApproval" => backend_pending_at_approval,
    "backendCLIWaitResult" => backend_cli_wait_result,
    "backendCLIWaitSourceSHA256" => wait_cli ? Digest::SHA256.file(wait_cli).hexdigest : nil,
    "terminalDeviceStatusReplies" => backend_device_replies,
    "lostAcknowledgementRetried" => lost_response, "states" => mutex.synchronize { states }, "fixtureErrors" => errors}
  FileUtils.mkdir_p(File.dirname(prefix))
  File.write("#{prefix}.json", JSON.pretty_generate(report) + "\n")
  File.write("#{prefix}.md", ["# WillDeep 原生状态 CLI 验证", "", "通过：#{passed}", "失败：#{failure || '无'}", "",
    report["scope"], "", "本机模型请求：#{requests}，原生状态报告：#{states.length}，注入一次丢失确认：#{lost_response}。", ""].join("\n"))
  FileUtils.remove_entry(root) if passed
end
puts JSON.generate({"passed" => passed, "failure" => failure, "report" => "#{prefix}.json"})
exit(passed ? 0 : 1)
