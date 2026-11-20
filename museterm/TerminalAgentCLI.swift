import Foundation

enum TerminalAgentCLI {
    /// Shared by CLI and MCP. Reporting secrets stay in private local binding files, never argv/output.
    static let script = #"""
SWIFT_REFERENCE_EPOCH = Time.utc(2001, 1, 1).to_f
STATUS_RESPONSE_MAX_BYTES = 131_072
STATUS_RESPONSE_TIMEOUT = 5
STATUS_RESPONSE_POLL_INTERVAL = 0.02

def explicit_agent_tab(value)
  raise "Use an explicit terminal UUID." unless value.to_s.match?(/\A[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}\z/)
  value
end

def agent_request(action, args)
  if action == "report_agent_state"
    return report_agent_binding(args)
  end
  source = backend_runtime_source(args["after"]) if ["read_session_events", "get_agent_state"].include?(action)
  if source
    fields = action == "get_agent_state" ? {"tab" => explicit_agent_tab(args["tab"])} : {"eventCursor" => args["after"], "eventLimit" => args["limit"]}.compact
    response = backend_endpoint_request(source, action, fields)
  else
    response = send_request(action: action, tab: action == "read_session_events" ? nil : explicit_agent_tab(args["tab"]),
      agent_kind: args["kind"], event_cursor: args["after"], event_limit: args["limit"])
  end
  raise(response["error"] || "Agent request failed.") unless response["ok"]
  if action == "bind_agent"
    response["bindingFile"] = store_agent_binding(args.fetch("tab"), response.delete("agentGrant"), response.delete("agentReportRoot"))
  end
  response
end

def store_agent_binding(tab, grant, report_root = nil)
  raise "Invalid status binding response." unless grant.is_a?(Hash) && grant["token"] && grant["runID"]
  directory = File.join(ROOT, "agent-bindings")
  FileUtils.mkdir_p(directory, mode: 0o700)
  FileUtils.chmod(0o700, directory)
  # Unique files preserve old run identities: stale hooks cannot borrow a replacement run's token.
  path = File.join(directory, "#{SecureRandom.uuid}.json")
  File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
    file.write(JSON.generate(grant.merge("tab" => tab, "sequence" => 0, "reportRoot" => report_root).compact))
  end
  path
end

def send_bound_agent_report(binding, report)
  root = binding["reportRoot"]
  return send_request(action: "report_agent_state", tab: explicit_agent_tab(binding.fetch("tab")), agent_report: report) unless root
  raise "Invalid status endpoint." unless root.is_a?(String) && root.start_with?("/")
  [root, File.join(root, "requests"), File.join(root, "responses")].each do |path|
    info = File.lstat(path)
    raise "Unsafe status endpoint." unless info.directory? && !info.symlink? && info.uid == Process.uid && (info.mode & 0o077).zero?
  end
  id = SecureRandom.uuid
  request_path = File.join(root, "requests", "#{id}.json")
  response_path = File.join(root, "responses", "#{id}.json")
  private_tool_request(request_path, {"id" => id, "action" => "report_agent_state",
    "tab" => explicit_agent_tab(binding.fetch("tab")), "agentReport" => report})
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + STATUS_RESPONSE_TIMEOUT
  until File.file?(response_path)
    raise "Status endpoint timed out." if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
    sleep STATUS_RESPONSE_POLL_INTERVAL
  end
  response = File.open(response_path, File::RDONLY | File::NOFOLLOW) do |file|
    info = file.stat
    raise "Unsafe status response." unless info.file? && info.uid == Process.uid && (info.mode & 0o077).zero? && info.size <= STATUS_RESPONSE_MAX_BYTES
    JSON.parse(file.read(STATUS_RESPONSE_MAX_BYTES + 1))
  end
  raise "Invalid status response." unless response["id"] == id && response["action"] == "report_agent_state"
  # Native status protocol 1 uses Foundation's reference-date numbers. Keep
  # CLI/MCP's existing RFC3339 presentation independent from that wire format.
  if response["agent"].is_a?(Hash)
    %w[updatedAt expiresAt].each do |key|
      value = response["agent"][key]
      response["agent"][key] = Time.at(value + SWIFT_REFERENCE_EPOCH).utc.iso8601 if value.is_a?(Numeric)
    end
  end
  response["app"] = response.delete("appName") if response.key?("appName")
  response["tabID"] = binding.fetch("tab")
  response
rescue JSON::ParserError, SystemCallError
  raise "Status endpoint unavailable."
ensure
  FileUtils.rm_f(request_path) if defined?(request_path) && request_path
  FileUtils.rm_f(response_path) if defined?(response_path) && response_path
end

def report_agent_binding(args)
  path = args.fetch("bindingFile")
  response = nil
  # Serialize hooks using the same binding; reserve a sequence before sending so a lost response
  # cannot cause the next hook to reuse an already accepted sequence.
  File.open(path, File::RDWR | File::NOFOLLOW) do |file|
    raise "Unsafe status binding permissions." unless file.stat.uid == Process.uid && (file.stat.mode & 0o077).zero?
    file.flock(File::LOCK_EX)
    binding = JSON.parse(file.read)
    binding["sequence"] = Integer(binding.fetch("sequence")) + 1
    report = binding.slice("instanceID", "runID", "token", "sequence").merge(
      "activity" => args.fetch("activity"), "blockReason" => args["blockReason"], "result" => args["result"]).compact
    file.rewind
    file.write(JSON.generate(binding))
    file.truncate(file.pos)
    file.flush
    response = send_bound_agent_report(binding, report)
  end
  raise(response["error"] || "Agent report failed.") unless response["ok"]
  response
rescue JSON::ParserError, KeyError, TypeError, ArgumentError
  raise "Invalid status binding or report."
end

def command_agent(args)
  operation = args.shift
  options = {}
  until args.empty?
    key = args.shift
    field = {"--tab" => "tab", "--kind" => "kind", "--binding" => "bindingFile",
      "--activity" => "activity", "--block-reason" => "blockReason", "--result" => "result",
      "--after" => "after", "--limit" => "limit"}[key]
    raise "Unknown agent option." unless field && !args.empty?
    value = args.shift
    options[field] = field == "after" ? JSON.parse(value) : field == "limit" ? Integer(value) : value
  end
  action = {"bind" => "bind_agent", "report" => "report_agent_state", "status" => "get_agent_state",
    "events" => "read_session_events"}[operation]
  raise "Use museterm agent bind|report|status|events." unless action
  print_json(agent_request(action, options))
end

def agent_mcp_tools
  [
    {"name" => "get_agent_state", "description" => "Read fresh Agent state and evidence for an explicit terminal UUID; idle does not mean success.",
     "inputSchema" => {"type" => "object", "properties" => {"tab" => {"type" => "string"}}, "required" => ["tab"]}},
    {"name" => "bind_agent", "description" => "Explicitly bind a new status-only reporter. Requires pairing, replaces the old binding, grants no terminal input permission. Returns a private binding file path, never its secret.",
     "inputSchema" => {"type" => "object", "properties" => {"tab" => {"type" => "string"}, "kind" => {"type" => "string", "enum" => ["claude", "codex", "willdeep"]}}, "required" => ["tab", "kind"]}},
    {"name" => "report_agent_state", "description" => "Report lifecycle through a private binding file. Send heartbeats within 120 seconds; silence becomes unknown. This never sends terminal input or renews its lease.",
     "inputSchema" => {"type" => "object", "properties" => {
       "bindingFile" => {"type" => "string"}, "activity" => {"type" => "string", "enum" => ["unknown", "working", "idle", "blocked", "exited"]},
       "blockReason" => {"type" => "string", "enum" => ["approval", "question", "other"]},
       "result" => {"type" => "string", "enum" => ["completed", "failed", "interrupted", "unknown"]}}, "required" => ["bindingFile", "activity"]}},
    {"name" => "read_session_events", "description" => "Read bounded metadata events after a cursor. Omit after to capture the current cursor. No waiting; expiry/restart require resnapshotting.",
     "inputSchema" => {"type" => "object", "properties" => {
       "after" => {"type" => "object", "properties" => {"appEpoch" => {"type" => "string"}, "sequence" => {"type" => "integer"}}, "required" => ["appEpoch", "sequence"]},
       "limit" => {"type" => "integer", "minimum" => 1, "maximum" => 1024}}}}
  ]
end
"""#
}
