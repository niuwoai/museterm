import Foundation

enum TerminalWaitCLI {
    static let script = #"""
class QTermWaitCancelled < StandardError; end

def wait_runtime_result(id, spec)
  runtime_path = File.join(ROOT, "runtime.json")
  return nil unless File.file?(runtime_path)
  runtime = JSON.parse(File.read(runtime_path))
  epoch = spec.dig("after", "appEpoch")
  return nil unless epoch.is_a?(String) && runtime["appEpoch"].is_a?(String) && runtime["cursor"].is_a?(Hash)
  return nil unless runtime["cursor"]["appEpoch"] == runtime["appEpoch"] && runtime["cursor"]["sequence"].is_a?(Integer)
  outcome = "appRestarted" if runtime["appEpoch"].downcase != epoch.downcase
  if !outcome && runtime["pid"].is_a?(Integer) && runtime["pid"] > 0
    begin
      Process.kill(0, runtime["pid"])
    rescue Errno::ESRCH
      outcome = "appExited"
    rescue Errno::EPERM
      # The process exists; inability to inspect it is not proof of exit.
    end
  end
  return nil unless outcome
  {"ok" => true, "id" => id, "version" => runtime["version"],
    "waitResult" => {"waitID" => id, "outcome" => outcome, "cursor" => runtime["cursor"]}}
rescue JSON::ParserError, SystemCallError, TypeError
  nil
end

def abandon_wait(id)
  ensure_dirs
  cancel_id = SecureRandom.uuid
  payload = {"id" => cancel_id, "action" => "cancel_wait", "waitID" => id,
    "controlID" => CONTROL_ID, "noResponse" => true}
  private_tool_request(File.join(REQUESTS, "#{cancel_id}.json"), payload)
rescue StandardError
  # The bounded server timeout is the fallback when the app has exited.
end

def private_tool_request(path, payload)
  temporary = "#{path}.#{SecureRandom.uuid}.tmp"
  File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(JSON.generate(payload)) }
  File.rename(temporary, path)
ensure
  FileUtils.rm_f(temporary) if temporary
end

def wait_tool(args)
  spec = args.fetch("spec")
  raise "Invalid wait specification." unless spec.is_a?(Hash)
  seconds = spec.fetch("timeoutSeconds", 30)
  raise "Invalid wait timeout." unless seconds.is_a?(Numeric)
  seconds = seconds.to_f
  raise "Wait timeout must be between 0 and 60 seconds." unless seconds.finite? && (0..60).cover?(seconds)
  response = send_request(action: "wait_session", wait_spec: spec, timeout_seconds: seconds + 5)
  raise(response["error"] || "Wait failed.") unless response["ok"]
  response
end

def attention_tool(name, args)
  response = send_request(action: name, tab: args["tab"], attention_id: args["itemID"], attention_version: args["version"])
  raise(response["error"] || "Attention request failed.") unless response["ok"]
  response
end

def wait_mcp_tools
  [
    {"name" => "list_attention", "description" => "List unresolved Agent questions and unread result summaries. Read and resolved are separate.",
     "inputSchema" => {"type" => "object", "properties" => {"tab" => {"type" => "string"}}}},
    {"name" => "acknowledge_attention", "description" => "Mark an exact item version as read. Requires pairing. Waiting questions stay unresolved; no terminal input is sent.",
     "inputSchema" => {"type" => "object", "properties" => {"itemID" => {"type" => "string"}, "version" => {"type" => "integer"}}, "required" => ["itemID", "version"]}},
    {"name" => "wait_session", "description" => "Wait asynchronously, up to 60 seconds, for a concrete command, Agent run, new attention/event, or output revision. Does not renew input leases. MCP cancellation and EOF release the waiter.",
     "inputSchema" => {"type" => "object", "properties" => {"spec" => {"type" => "object", "properties" => {
       "condition" => {"type" => "string", "enum" => ["commandFinished", "agentState", "attention", "outputChanged", "events"]},
       "after" => {"type" => "object", "properties" => {"appEpoch" => {"type" => "string"}, "sequence" => {"type" => "integer"}}, "required" => ["appEpoch", "sequence"]},
       "tabID" => {"type" => "string"}, "commandID" => {"type" => "string"}, "instanceID" => {"type" => "string"}, "runID" => {"type" => "string"},
       "activity" => {"type" => "string", "enum" => ["unknown", "working", "idle", "blocked", "exited"]}, "revision" => {"type" => "integer"},
       "timeoutSeconds" => {"type" => "number", "minimum" => 0, "maximum" => 60}}, "required" => ["condition", "after"]}}, "required" => ["spec"]}}
  ]
end

def command_attention(args)
  options = {}
  action = args.first == "read" ? (args.shift; "acknowledge_attention") : "list_attention"
  until args.empty?
    field = {"--tab" => "tab", "--item" => "itemID", "--version" => "version"}[args.shift]
    raise "Invalid attention option." unless field && !args.empty?
    options[field] = field == "version" ? Integer(args.shift) : args.shift
  end
  print_json(attention_tool(action, options))
end

def command_wait(args)
  raise "Use qterm wait SPEC_JSON." unless args.length == 1
  print_json(wait_tool({"spec" => JSON.parse(args.first)}))
rescue JSON::ParserError
  raise "Invalid wait specification JSON."
end
"""#
}
