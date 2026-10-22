import Foundation

enum TerminalAgentCLI {
    /// Shared by CLI and MCP. Reporting secrets stay in private local binding files, never argv/output.
    static let script = #"""
def explicit_agent_tab(value)
  raise "Use an explicit terminal UUID." unless value.to_s.match?(/\A[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}\z/)
  value
end

def agent_request(action, args)
  if action == "report_agent_state"
    return report_agent_binding(args)
  end
  response = send_request(action: action, tab: action == "read_session_events" ? nil : explicit_agent_tab(args["tab"]),
    agent_kind: args["kind"], event_cursor: args["after"], event_limit: args["limit"])
  raise(response["error"] || "Agent request failed.") unless response["ok"]
  if action == "bind_agent"
    response["bindingFile"] = store_agent_binding(args.fetch("tab"), response.delete("agentGrant"))
  end
  response
end

def store_agent_binding(tab, grant)
  raise "Invalid status binding response." unless grant.is_a?(Hash) && grant["token"] && grant["runID"]
  directory = File.join(ROOT, "agent-bindings")
  FileUtils.mkdir_p(directory, mode: 0o700)
  FileUtils.chmod(0o700, directory)
  # Unique files preserve old run identities: stale hooks cannot borrow a replacement run's token.
  path = File.join(directory, "#{SecureRandom.uuid}.json")
  File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
    file.write(JSON.generate(grant.merge("tab" => tab, "sequence" => 0)))
  end
  path
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
    response = send_request(action: "report_agent_state", tab: explicit_agent_tab(binding.fetch("tab")), agent_report: report)
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
  raise "Use qterm agent bind|report|status|events." unless action
  print_json(agent_request(action, options))
end

def agent_mcp_tools
  [
    {"name" => "get_agent_state", "description" => "Read fresh Agent state and evidence for an explicit terminal UUID; idle does not mean success.",
     "inputSchema" => {"type" => "object", "properties" => {"tab" => {"type" => "string"}}, "required" => ["tab"]}},
    {"name" => "bind_agent", "description" => "Explicitly bind a new status-only reporter. Requires pairing, replaces the old binding, grants no terminal input permission. Returns a private binding file path, never its secret.",
     "inputSchema" => {"type" => "object", "properties" => {"tab" => {"type" => "string"}, "kind" => {"type" => "string", "enum" => ["claude", "codex"]}}, "required" => ["tab", "kind"]}},
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
