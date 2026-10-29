#!/usr/bin/env ruby
require "json"
require "open3"
require "digest"
require "time"
require_relative "support/runtime_probe_client"

phase, metadata_path, terminal_id = ARGV
abort "Use start|kill|offline|resume|acknowledged|cleanup QA_METADATA TERMINAL_UUID" unless %w[start kill offline resume acknowledged cleanup].include?(phase)
metadata = JSON.parse(File.read(metadata_path))
root = metadata.fetch("root")
abort "Only a private owned QA root is allowed" unless root.start_with?("/private/tmp/museterm-native-qa-") && File.lstat(root).uid == Process.uid && File.stat(root).mode & 0o077 == 0
app = metadata.fetch("app")
abort "Unexpected QA app path" unless app == File.join(root, "MuseTermQA.app")
identifier, _, status = Open3.capture3("/usr/libexec/PlistBuddy", "-c", "Print :CFBundleIdentifier", File.join(app, "Contents/Info.plist"))
abort "Only an isolated goaltests app is allowed" unless status.success? && identifier.strip.start_with?("im.some.museterm.goaltests")
abort "Use an exact terminal UUID" unless terminal_id&.match?(/\A[0-9A-Fa-f-]{36}\z/)
trace_path = File.join(root, "checkpoint-crash.json")
trace = File.file?(trace_path) ? JSON.parse(File.read(trace_path)) : {}
backend = RuntimeProbeClient.new(metadata.fetch("backend"))
backend_pid = JSON.parse(File.read(File.join(metadata.fetch("backend"), "native-tools/runtime.json"))).fetch("pid")

def await_ui_checkpoint
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 12
  loop do
    value = yield
    return value if value
    raise "QA checkpoint condition timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    sleep 0.02
  end
end

call = lambda do |action, fields = {}|
  response = backend.request(action, fields)
  raise "Runtime request rejected: #{response['error']}" unless response["ok"]
  response
end
info = lambda { call.call("list").fetch("sessions").find { |value| value["id"].casecmp?(terminal_id) } || raise("Original terminal missing") }
target = lambda do
  value = info.call
  {"sessionID" => value.fetch("id"), "generation" => value.fetch("generation"), "controlEpoch" => value.fetch("controlEpoch")}
end
input = lambda do |text|
  value = info.call
  raise "QA terminal unexpectedly controlled" if value["controlOwner"]
  call.call("input", target.call.merge("source" => "human", "inputSequence" => value.fetch("nextInputSequence"), "data" => [text + "\n"].pack("m0")))
end
ui_runtime = lambda { JSON.parse(File.read(File.join(metadata.fetch("tools"), "runtime.json"))) }
ui_state = lambda { JSON.parse(File.read(File.join(metadata.fetch("tools"), "state.json"))) }
saved = lambda do
  Dir.glob(File.join(metadata.fetch("backend"), "workspaces/*.json")).filter_map do |path|
    record = JSON.parse(File.read(path))
    record.fetch("snapshot").fetch("tabs").find { |tab| tab["terminalID"]&.casecmp?(terminal_id) }&.fetch("runtimeRenderedCursor", nil)
  end.first
end
items = lambda { call.call("listAttention", {"sessionID" => terminal_id}).fetch("attention") }

begin
  case phase
  when "start"
    raise "QA must have an inactive original terminal and a second selected terminal" if ui_state.call["selectedTabID"]&.casecmp?(terminal_id)
    original = info.call
    baseline = await_ui_checkpoint { saved.call }
    runtime = ui_runtime.call
    trace = {"version" => runtime.fetch("version"), "app" => app, "startedAt" => Time.now.iso8601, "backendPID" => backend_pid,
      "appPIDBefore" => runtime.fetch("pid"), "uiEpochBefore" => runtime.fetch("appEpoch"),
      "original" => original.slice("id", "pid", "generation"), "sessionIDs" => call.call("list").fetch("sessions").map { |value| value["id"] },
      "selectedBefore" => ui_state.call["selectedTabID"], "baseline" => baseline,
      "helperSHA256" => Digest::SHA256.file(File.join(app, "Contents/Helpers/museterm-runtime")).hexdigest}
    input.call("cd '#{root}'; printf '\\a__QA_CP_START\\n'; n=0; while [ ! -f '#{root}/stop-qa' ] && [ \"$n\" -lt 300 ]; do printf '__QA_CP_TICK_%s\\n' \"$n\"; n=$((n+1)); sleep 0.05; done; printf '__QA_CP_DONE\\n'")
    first = await_ui_checkpoint { value = saved.call; value if value && value["offset"] > baseline["offset"] }
    second = await_ui_checkpoint { value = saved.call; value if value && value["offset"] > first["offset"] }
    File.write(File.join(root, "stop-qa"), "")
    await_ui_checkpoint do
      output = call.call("read", target.call).fetch("data", "").unpack1("m0")
      output.match?(/(?:^|\r?\n)__QA_CP_DONE\r?\n/)
    end
    checkpoint = await_ui_checkpoint { value = saved.call; value if value && value["offset"] == info.call["outputOffset"] }
    pending = items.call
    raise "Expected one unread ordinary bell" unless pending.length == 1 && pending.first["kind"] == "bell" && pending.first["readAt"].nil?
    trace.merge!("firstDuringOutput" => first, "secondDuringOutput" => second, "checkpointBeforeKill" => checkpoint,
      "bellID" => pending.first.fetch("id"), "commandIDsBeforeKill" => info.call.fetch("commands", []).map { |value| value["id"] })
  when "kill"
    pid = trace.fetch("appPIDBefore")
    command, _, status = Open3.capture3("/bin/ps", "-p", pid.to_s, "-o", "command=")
    raise "PID is not the owned isolated QA app" unless status.success? && command.strip.start_with?(File.join(app, "Contents/MacOS/MuseTerm"))
    Process.kill("KILL", pid)
    await_ui_checkpoint do
      begin
        Process.kill(0, pid); false
      rescue Errno::ESRCH
        true
      end
    end
    actual = info.call
    raise "UI kill replaced terminal process" unless trace.fetch("original").all? { |key, value| actual[key] == value }
    trace["forcedKillVerified"] = true
  when "offline"
    raise "Kill phase missing" unless trace["forcedKillVerified"]
    input.call("printf '\\a__QA_CP_OFFLINE\\n'")
    await_ui_checkpoint { items.call.first&.dig("terminal", "occurrences") == 2 }
    trace["offlineOffset"] = info.call.fetch("outputOffset")
    trace["offlineCommandIDs"] = info.call.fetch("commands", []).map { |value| value["id"] } - trace.fetch("commandIDsBeforeKill")
    raise "Offline command marker not observed" if trace["offlineCommandIDs"].empty?
  when "resume"
    runtime = await_ui_checkpoint { value = ui_runtime.call; value if value["pid"] != trace.fetch("appPIDBefore") && value["appEpoch"] != trace.fetch("uiEpochBefore") }
    state = await_ui_checkpoint do
      value = ui_state.call
      tab = value.fetch("tabs").find { |entry| entry["id"].casecmp?(terminal_id) }
      value if tab && tab.fetch("history").include?("__QA_CP_OFFLINE") && tab.dig("runtime", "connected")
    end
    actual = info.call
    raise "Relaunch replaced original process" unless trace.fetch("original").all? { |key, value| actual[key] == value }
    tab = state.fetch("tabs").find { |entry| entry["id"].casecmp?(terminal_id) }
    ids = tab.fetch("commandBlocks").map { |value| value["id"] }
    raise "Already rendered historical command replayed as live" unless (ids & trace.fetch("commandIDsBeforeKill")).empty?
    raise "Offline suffix command lost" unless (trace.fetch("offlineCommandIDs") - ids).empty?
    pending = items.call
    raise "Relaunch duplicated or resolved ordinary reminder" unless pending.length == 1 && pending.first["id"] == trace.fetch("bellID") && pending.first.dig("terminal", "occurrences") == 2 && pending.first["readAt"].nil?
    ui_items = state.fetch("attentionItems").select { |entry| entry["tabID"].casecmp?(terminal_id) }
    raise "UI does not show the same single item" unless ui_items.length == 1 && ui_items.first["id"] == trace.fetch("bellID")
    trace.merge!("appPIDAfter" => runtime.fetch("pid"), "uiEpochAfter" => runtime.fetch("appEpoch"),
      "selectedAfter" => state["selectedTabID"], "liveCommandIDsAfter" => ids, "resumed" => true)
  when "acknowledged"
    raise "Actual UI acknowledgement did not resolve ordinary reminder" unless items.call.empty?
    state = await_ui_checkpoint do
      value = ui_state.call
      value if value["selectedTabID"]&.casecmp?(terminal_id) && value.fetch("attentionItems").none? { |item| item["tabID"].casecmp?(terminal_id) }
    end
    trace["uiReadVerified"] = true
    trace["selectedAfterRead"] = state.fetch("selectedTabID")
  when "cleanup"
    # Caller must quit the QA UI first. Never stop a service with unknown terminals.
    begin
      Process.kill(0, trace.fetch("appPIDAfter"))
      raise "Quit the owned QA UI before cleanup"
    rescue Errno::ESRCH
      # Expected: only the independent backend should remain.
    end
    raise "Unexpected terminal in owned QA service" unless (call.call("list").fetch("sessions").map { |value| value["id"] } - trace.fetch("sessionIDs")).empty?
    call.call("list").fetch("sessions").each do |value|
      call.call("close", {"sessionID" => value.fetch("id"), "generation" => value.fetch("generation"), "controlEpoch" => value.fetch("controlEpoch")})
    end
    call.call("shutdownIfEmpty")
    await_ui_checkpoint do
      begin
        Process.kill(0, backend_pid); false
      rescue Errno::ESRCH
        true
      end
    end
    trace["ownedServiceCleanupVerified"] = true
  end
  trace["lastPhase"] = phase
  File.open(trace_path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(JSON.pretty_generate(trace) + "\n") }
  puts JSON.generate({"phase" => phase, "passed" => true, "trace" => trace_path})
ensure
  backend.close
end
